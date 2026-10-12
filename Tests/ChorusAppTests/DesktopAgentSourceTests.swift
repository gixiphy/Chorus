import ChorusCore
import Darwin
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("DesktopAgentSource")
struct DesktopAgentSourceTests {
    private let codexPath = "/Applications/Codex.app/Contents/Resources/codex"
    private let selfUID = getuid()

    private func codexProcess(
        pid: Int32 = 42,
        startTime: Double? = 1,
        uid: uid_t? = nil
    ) -> DesktopAgentProcess {
        DesktopAgentProcess(
            pid: pid,
            comm: "codex",
            executablePath: codexPath,
            arguments: [codexPath, "app-server"],
            startTime: startTime,
            uid: uid ?? selfUID
        )
    }

    @Test("V-C07-3 process + signature + fresh mtime → contributing report")
    func workingWhenFresh() async {
        let now = Date(timeIntervalSince1970: 7_000_000)
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([codexProcess()]),
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/rollout-a.jsonl", mtime: now.addingTimeInterval(-10)),
            ]),
            now: { now }
        )
        source.start(schedulePolling: false)
        await source.refresh()
        #expect(source.report.count == 1)
        #expect(source.report.first?.id == "desktop.codex")
        #expect(source.report.first?.isWorkingNow == false)
        #expect(source.report.first?.lastWorkingAt != nil)
        source.stop()
    }

    @Test("V-C07-3 stale mtime does not report")
    func staleMtime() async {
        let now = Date(timeIntervalSince1970: 7_100_000)
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([codexProcess()]),
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/rollout-old.jsonl", mtime: now.addingTimeInterval(-400)),
            ]),
            now: { now }
        )
        source.start(schedulePolling: false)
        await source.refresh()
        #expect(source.report.isEmpty)
        source.stop()
    }

    @Test("V-C07-3 signature failure does not report")
    func signatureFails() async {
        let now = Date(timeIntervalSince1970: 7_200_000)
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([codexProcess()]),
            verifier: FakeVerifier(ok: false),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/rollout-a.jsonl", mtime: now.addingTimeInterval(-10)),
            ]),
            now: { now }
        )
        source.start(schedulePolling: false)
        await source.refresh()
        #expect(source.report.isEmpty)
        source.stop()
    }

    @Test("V-C07-3 no process → no report")
    func noProcess() async {
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([]),
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/rollout-a.jsonl", mtime: Date()),
            ])
        )
        source.start(schedulePolling: false)
        await source.refresh()
        #expect(source.report.isEmpty)
        source.stop()
    }

    @Test("V-C07-6 future mtime stable clamp across ticks")
    func futureMtimeStableClamp() async {
        let now = Date(timeIntervalSince1970: 7_300_000)
        let future = now.addingTimeInterval(3_600)
        var clock = now
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([codexProcess(pid: 9)]),
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([(id: "/tmp/rollout-future.jsonl", mtime: future)]),
            now: { clock }
        )
        source.start(schedulePolling: false)
        await source.refresh()
        let first = source.report.first?.lastWorkingAt
        #expect(first == now)

        clock = now.addingTimeInterval(60)
        await source.refresh()
        #expect(source.report.first?.lastWorkingAt == first)
        source.stop()
    }

    @Test("C7-4 other-user signed Codex rejected")
    func otherUserRejected() async {
        let now = Date(timeIntervalSince1970: 7_400_000)
        let other = selfUID &+ 1
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([codexProcess(uid: other)]),
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/rollout-a.jsonl", mtime: now.addingTimeInterval(-10)),
            ]),
            now: { now }
        )
        source.currentUID = { selfUID }
        source.start(schedulePolling: false)
        await source.refresh()
        #expect(source.report.isEmpty)
        source.stop()
    }

    @Test("C7-4 unavailable start time rejected")
    func nilStartRejected() async {
        let now = Date(timeIntervalSince1970: 7_410_000)
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([codexProcess(startTime: nil)]),
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/rollout-a.jsonl", mtime: now.addingTimeInterval(-10)),
            ]),
            now: { now }
        )
        source.start(schedulePolling: false)
        await source.refresh()
        #expect(source.report.isEmpty)
        source.stop()
    }

    @Test("C7-4 PID reuse invalidates cached success; cache stays bounded")
    func pidReuseAndCacheBound() async {
        let now = Date(timeIntervalSince1970: 7_420_000)
        let lister = MutableDesktopLister([codexProcess(pid: 99, startTime: 100)])
        let verifier = CountingVerifier(ok: true)
        let source = DesktopAgentSource(
            lister: lister,
            verifier: verifier,
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/rollout-a.jsonl", mtime: now.addingTimeInterval(-10)),
            ]),
            now: { now }
        )
        source.start(schedulePolling: false)
        await source.refresh()
        #expect(source.report.count == 1)
        #expect(source.signatureCacheCount == 1)
        let callsAfterFirst = verifier.calls

        // 同 pid、新 start time → 舊 cache key 被 prune，需重新驗簽。
        lister.processes = [codexProcess(pid: 99, startTime: 200)]
        await source.refresh()
        #expect(source.report.count == 1)
        #expect(verifier.calls > callsAfterFirst)
        #expect(source.signatureCacheCount == 1)

        lister.processes = []
        await source.refresh()
        #expect(source.report.isEmpty)
        #expect(source.signatureCacheCount == 0)

        source.stop()
        #expect(source.signatureCacheCount == 0)
    }

    @Test("C7-2 stop during scan discards late result")
    func stopDiscardsLate() async {
        let now = Date(timeIntervalSince1970: 7_430_000)
        let gate = SyncGate()
        let lister = GatedDesktopLister(processes: [codexProcess()], gate: gate)
        let source = DesktopAgentSource(
            lister: lister,
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/rollout-a.jsonl", mtime: now.addingTimeInterval(-10)),
            ]),
            now: { now }
        )
        source.start(schedulePolling: false)
        let task = Task { await source.refresh() }
        // list 在 detached utility 上阻塞；稍等進入閘門。
        await gate.waitUntilEntered()
        source.stop()
        #expect(source.report.isEmpty)
        gate.open()
        await task.value
        #expect(source.report.isEmpty)
    }

    @Test("Claude desktop source disabled even when path matches")
    func claudeDisabled() async {
        #expect(DesktopAgentMatcher.claudeDesktopSourceEnabled == false)
        let path = "/Users/test/Library/Application Support/Claude/claude-code/1.0.0/claude"
        let process = DesktopAgentProcess(
            pid: 7,
            comm: "claude",
            executablePath: path,
            arguments: [path],
            startTime: 1,
            uid: selfUID
        )
        let now = Date()
        let source = DesktopAgentSource(
            lister: StaticDesktopLister([process]),
            verifier: FakeVerifier(ok: true),
            transcripts: StaticTranscriptScanner([
                (id: "/tmp/claude.jsonl", mtime: now),
            ]),
            now: { now }
        )
        source.start(schedulePolling: false)
        await source.refresh()
        #expect(source.report.isEmpty)
        source.stop()
    }
    @Test("C7-4 metadata changes during argv reads reject the candidate")
    func metadataIdentityRace() {
        var start = 1.0
        let candidate = SystemDesktopAgentProcessLister.stableCandidate(
            pid: 42, comm: "codex", currentUID: selfUID,
            identity: { (start, selfUID) },
            arguments: { start = 2; return [codexPath, "app-server"] },
            path: { codexPath }
        )
        #expect(candidate == nil)
        var reads = 0
        let exec = SystemDesktopAgentProcessLister.stableCandidate(
            pid: 42, comm: "codex", currentUID: selfUID,
            identity: { (1, selfUID) }, arguments: { [codexPath, "app-server"] },
            path: { reads += 1; return reads == 1 ? codexPath : "/tmp/other" }
        )
        #expect(exec == nil)
    }

    @Test("C7-4 exec/exit during signature or transcript invalidates attribution and cache")
    func suspendedIdentityChanges() async {
        for stage in 0..<5 {
            let clock = Date(timeIntervalSince1970: 7_500_000)
            let gate = SyncGate()
            let lister = LockedDesktopLister([codexProcess()])
            let scanner = GatedTranscriptScanner(mtime: clock)
            let verifier = GatedSignatureVerifier()
            let source = DesktopAgentSource(lister: lister, verifier: verifier,
                                            transcripts: scanner, now: { clock })
            source.start(schedulePolling: false)
            if stage == 2 || stage == 3 {
                await source.refresh() // populate accepted cache
                #expect(source.signatureCacheCount == 1)
                if stage == 2 {
                    lister.gate = gate
                    lister.gateCall = lister.calls + 2 // live recheck on cache hit
                } else {
                    scanner.gate = gate // cached success must also survive transcript read
                }
            } else if stage == 0 {
                verifier.gate = gate
            } else {
                scanner.gate = gate
            }
            let task = Task { await source.refresh() }
            await gate.waitUntilEntered()
            var changed = codexProcess()
            changed.executablePath = "/tmp/other" // exec can preserve PID/start/uid
            changed.arguments = ["/tmp/other"]
            lister.set(stage == 4 ? [] : [changed])
            gate.open()
            await task.value
            #expect(source.report.isEmpty)
            #expect(source.signatureCacheCount == 0)
            source.stop()
        }
    }

}

// MARK: - Test helpers

struct GatedDesktopLister: DesktopAgentProcessListing {
    var processes: [DesktopAgentProcess]
    let gate: SyncGate

    func listDesktopCandidates() -> [DesktopAgentProcess] {
        gate.enterAndWait()
        return processes
    }
}

final class LockedDesktopLister: DesktopAgentProcessListing, @unchecked Sendable {
    private let lock = NSLock()
    private var processes: [DesktopAgentProcess]
    private(set) var calls = 0
    var gate: SyncGate?
    var gateCall = 0
    init(_ processes: [DesktopAgentProcess]) { self.processes = processes }
    func set(_ processes: [DesktopAgentProcess]) {
        lock.lock(); self.processes = processes; lock.unlock()
    }
    func listDesktopCandidates() -> [DesktopAgentProcess] {
        lock.lock()
        calls += 1
        let pending = calls == gateCall ? gate : nil
        lock.unlock()
        pending?.enterAndWait()
        lock.lock(); defer { lock.unlock() }
        return processes
    }
}
final class GatedSignatureVerifier: CodeSignatureVerifying, @unchecked Sendable {
    var gate: SyncGate?
    func teamIdentifierMatches(pid: Int32, teamID: String) -> Bool {
        gate?.enterAndWait()
        return true
    }
}
final class GatedTranscriptScanner: DesktopTranscriptScanning, @unchecked Sendable {
    let mtime: Date
    var gate: SyncGate?
    init(mtime: Date) { self.mtime = mtime }
    func latestMtimes(kind: DesktopAgentKind) -> [(id: String, mtime: Date)] {
        gate?.enterAndWait()
        return [("/fake/rollout.jsonl", mtime)]
    }
}
