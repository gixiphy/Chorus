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
        for _ in 0..<50 {
            if gate.isWaitingForTest { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
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
