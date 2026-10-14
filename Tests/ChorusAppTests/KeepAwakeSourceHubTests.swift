import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("KeepAwakeSourceHub", .timeLimit(.minutes(1)))
struct KeepAwakeSourceHubTests {
    @Test("P2: 100 identical recomputes do not re-notify onBusyChanged")
    func identicalRecomputeDoesNotNotify() {
        var clock = Date(timeIntervalSince1970: 9_000_000)
        let leases = KeepAwakeLeaseSource(
            wallNow: { clock },
            uptimeNow: { clock.timeIntervalSince1970 }
        )
        let hub = KeepAwakeSourceHub(
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil, now: { clock }),
            leases: leases,
            tickInterval: .seconds(3_600),
            now: { clock }
        )
        hub.configure(
            KeepAwakeSourceSettings(orcaEnabled: false, desktopAgentsEnabled: false, grokBotEnabled: false)
        )
        var notifies = 0
        hub.onBusyChanged = { notifies += 1 }
        hub.start()
        _ = leases.hold(id: "stable", ttl: 600)
        #expect(hub.isBusy)
        let afterHold = notifies
        let suppressedBefore = hub.notifyStats.suppressedIdentical
        for _ in 0..<100 {
            hub.recompute()
        }
        #expect(notifies == afterHold)
        #expect(hub.notifyStats.suppressedIdentical - suppressedBefore == 100)
        hub.stop()
    }

    final class FakePresence: OrcaPresenceChecking, @unchecked Sendable {
        var running = true
        func isOrcaRunning() -> Bool { running }
    }

    final class FakeRunner: OrcaCommandRunning, @unchecked Sendable {
        var results: [OrcaCommandRunResult] = []
        var calls = 0
        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            timeout: Duration,
            stdoutLimit: Int
        ) async -> OrcaCommandRunResult {
            calls += 1
            if results.isEmpty {
                let idle = #"{"ok":true,"result":{"worktrees":[],"truncated":false}}"#
                return OrcaCommandRunResult(
                    exitCode: 0,
                    stdout: Data(idle.utf8),
                    stderr: Data(),
                    timedOut: false,
                    killed: false
                )
            }
            let next = results.removeFirst()
            return next
        }
    }

    final class FakeAppChecker: AppPresenceChecking, @unchecked Sendable {
        var present = false
        func isPresent(bundleIDs: Set<String>, appPaths: Set<String>) -> Bool { present }
    }

    private func makeHub(
        now: @escaping () -> Date,
        leases: KeepAwakeLeaseSource? = nil,
        tickInterval: Duration = .seconds(30),
        appPresence: AppPresenceSource? = nil
    ) -> (KeepAwakeSourceHub, KeepAwakeLeaseSource) {
        let leaseSource = leases ?? KeepAwakeLeaseSource(
            wallNow: now,
            uptimeNow: { now().timeIntervalSince1970 }
        )
        let hub = KeepAwakeSourceHub(
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil, now: now),
            orca: OrcaActivitySource(
                runner: FakeRunner(), workspaceCenter: NotificationCenter(),
                presence: FakePresence(),
                now: now,
                normalInterval: .seconds(30),
                backoffInterval: .seconds(120)
            ),
            desktop: DesktopAgentSource(
                lister: StaticDesktopLister([]),
                verifier: FakeVerifier(ok: false),
                transcripts: StaticTranscriptScanner([]),
                now: now
            ),
            leases: leaseSource,
            appPresence: appPresence ?? AppPresenceSource(checker: FakeAppChecker(), now: now),
            tickInterval: tickInterval,
            now: now
        )
        hub.agentActivity.chromiumThrottleWarningOverride = false
        hub.configure(
            KeepAwakeSourceSettings(
                orcaEnabled: false,
                desktopAgentsEnabled: false,
                grokBotEnabled: false
            )
        )
        return (hub, leaseSource)
    }

    @Test("V-C07-1 OR semantics via leases")
    func orSemantics() async {
        var clock = Date(timeIntervalSince1970: 2_000_000)
        let (hub, leases) = makeHub(now: { clock })
        defer { hub.stop() }
        hub.start()
        #expect(!hub.isBusy)

        _ = leases.hold(id: "bot", ttl: 60)
        #expect(hub.isBusy)
        #expect(hub.busy.contributing.contains { $0.id == "lease:bot" })
    }

    @Test("C7-1 lease TTL advances on hub tick without manual refresh")
    func leaseTTLViaTick() async throws {
        var clock = Date(timeIntervalSince1970: 3_000_000)
        let t0 = clock
        let (hub, leases) = makeHub(now: { clock }, tickInterval: .milliseconds(15))
        hub.start()
        _ = leases.hold(id: "short", ttl: 30)
        #expect(hub.isBusy)

        // t=30：剛好到期邊界；tick 必須自己 refresh leases。
        clock = t0.addingTimeInterval(30)
        try await Task.sleep(for: .milliseconds(40))
        hub.tick()
        let atExpiry = hub.reports.first { $0.id == "lease:short" }
        #expect(atExpiry?.isWorkingNow == false)
        #expect(atExpiry?.lastWorkingAt == t0.addingTimeInterval(30))
        #expect(hub.isBusy) // 仍在 300s grace

        clock = t0.addingTimeInterval(329)
        hub.tick()
        #expect(hub.isBusy)

        clock = t0.addingTimeInterval(330)
        hub.tick()
        #expect(!hub.isBusy)
        #expect(!hub.reports.contains { $0.id == "lease:short" })

        let snap = leases.snapshot()
        #expect(snap.active.isEmpty)
        #expect(snap.tombstones.isEmpty)
        hub.stop()
    }

    @Test("V-C07-1 grace expiry via tick flips isBusy")
    func graceTick() async throws {
        var clock = Date(timeIntervalSince1970: 3_100_000)
        let (hub, leases) = makeHub(now: { clock }, tickInterval: .milliseconds(20))
        var flips: [Bool] = []
        hub.onBusyChanged = { flips.append(hub.isBusy) }
        hub.start()
        _ = leases.hold(id: "short", ttl: 30)
        #expect(hub.isBusy)

        clock = clock.addingTimeInterval(31)
        hub.tick()
        #expect(hub.isBusy)

        clock = clock.addingTimeInterval(300)
        hub.tick()
        #expect(!hub.isBusy)
        #expect(flips.contains(false))
        hub.stop()
    }

    @Test("V-C07-1 stop does not call onBusyChanged")
    func stopSilent() {
        var clock = Date(timeIntervalSince1970: 4_000_000)
        let (hub, leases) = makeHub(now: { clock })
        var calls = 0
        hub.onBusyChanged = { calls += 1 }
        hub.start()
        _ = leases.hold(id: "x", ttl: 60)
        let before = calls
        hub.stop()
        #expect(calls == before)
        #expect(!hub.isBusy)
        #expect(hub.reports.isEmpty)
    }

    @Test("C7-6 notify when contributing/details change while busy stays true")
    func notifyWhileBusyRemains() {
        var clock = Date(timeIntervalSince1970: 4_500_000)
        let (hub, leases) = makeHub(now: { clock })
        var calls = 0
        hub.onBusyChanged = { calls += 1 }
        hub.start()
        _ = leases.hold(id: "a", ttl: 600)
        let afterFirst = calls
        #expect(hub.isBusy)
        _ = leases.hold(id: "b", ttl: 600)
        #expect(hub.isBusy)
        #expect(calls > afterFirst)
        #expect(hub.busy.contributing.contains { $0.id == "lease:b" })
        hub.stop()
    }

    @Test("C7-9 clearImmediately while running clears hub busy synchronously")
    func clearLeasesHookImmediate() {
        var clock = Date(timeIntervalSince1970: 4_600_000)
        let (hub, leases) = makeHub(now: { clock })
        hub.start()
        _ = leases.hold(id: "only", ttl: 600)
        #expect(hub.isBusy)

        // 模擬 C09 clearLeases → leases.clearImmediately（automation disable／token rotation）。
        leases.clearImmediately()
        #expect(leases.report.isEmpty)
        #expect(!hub.isBusy)
        #expect(!hub.busy.contributing.contains { $0.kind == .lease })
        #expect(leases.snapshot().tombstones.isEmpty)

        var calls = 0
        hub.onBusyChanged = { calls += 1 }
        hub.stop()
        #expect(calls == 0)
    }

    @Test("V1-10 present → stop → absent → much-later restart does not fabricate busy")
    func grokEvidenceClearedOnStop() {
        var clock = Date(timeIntervalSince1970: 7_000_000)
        let checker = FakeAppChecker()
        checker.present = true
        let presence = AppPresenceSource(checker: checker, now: { clock })
        let (hub, _) = makeHub(now: { clock }, appPresence: presence)
        hub.configure(
            KeepAwakeSourceSettings(orcaEnabled: false, desktopAgentsEnabled: false, grokBotEnabled: true)
        )
        hub.start()
        presence.refresh(notify: true)
        #expect(hub.isBusy)

        hub.stop()
        checker.present = false
        clock = clock.addingTimeInterval(10_000) // ≫ grace
        hub.configure(
            KeepAwakeSourceSettings(orcaEnabled: false, desktopAgentsEnabled: false, grokBotEnabled: true)
        )
        hub.start()
        presence.refresh(notify: true)
        #expect(!hub.isBusy)
        #expect(!hub.reports.contains { $0.id == "app:grok-bot" })
        hub.stop()
    }

    @Test("V1-2 unchanged configure is idempotent under drifting wall")
    func configureIdempotentWithLease() {
        var uptime = 50.0
        var wallTick = 0
        let leases = KeepAwakeLeaseSource(
            wallNow: {
                wallTick += 1
                return Date(timeIntervalSince1970: 8_000_000 + Double(wallTick))
            },
            uptimeNow: { uptime }
        )
        var depth = 0
        var maxDepth = 0
        var busyChanges = 0
        let hub = KeepAwakeSourceHub(
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil, now: {
                Date(timeIntervalSince1970: uptime)
            }),
            orca: OrcaActivitySource(
                runner: FakeRunner(), workspaceCenter: NotificationCenter(),
                presence: FakePresence(), now: { Date(timeIntervalSince1970: uptime) }
            ),
            desktop: DesktopAgentSource(
                lister: StaticDesktopLister([]),
                verifier: FakeVerifier(ok: false),
                transcripts: StaticTranscriptScanner([]),
                now: { Date(timeIntervalSince1970: uptime) }
            ),
            leases: leases,
            appPresence: AppPresenceSource(
                checker: FakeAppChecker(),
                now: { Date(timeIntervalSince1970: uptime) }
            ),
            now: { Date(timeIntervalSince1970: uptime) }
        )
        hub.agentActivity.chromiumThrottleWarningOverride = false
        let settings = KeepAwakeSourceSettings(
            orcaEnabled: false, desktopAgentsEnabled: false, grokBotEnabled: false
        )
        hub.configure(settings)
        hub.onBusyChanged = {
            depth += 1
            maxDepth = max(maxDepth, depth)
            busyChanges += 1
            // Re-enter configure like KeepAwakeController.reevaluate does.
            hub.configure(settings)
            depth -= 1
        }
        hub.start()
        _ = leases.hold(id: "reentry", ttl: 120)
        #expect(hub.isBusy)
        #expect(maxDepth <= 2)
        let before = busyChanges
        hub.configure(settings) // unchanged — no notify
        #expect(busyChanges == before)
        hub.stop()
    }

    @Test("C7-5 Grok exit grace from exit time; tick self-corrects")
    func grokExitGrace() {
        var clock = Date(timeIntervalSince1970: 6_500_000)
        let checker = FakeAppChecker()
        checker.present = true
        let presence = AppPresenceSource(checker: checker, now: { clock })
        let (hub, _) = makeHub(now: { clock }, appPresence: presence)
        hub.configure(
            KeepAwakeSourceSettings(orcaEnabled: false, desktopAgentsEnabled: false, grokBotEnabled: true)
        )
        hub.start()
        presence.refresh(notify: true)
        #expect(hub.isBusy)

        // 模擬錯過 terminate：仍顯示 present 快取；下一 tick 校正。
        checker.present = false
        clock = clock.addingTimeInterval(600)
        hub.tick()
        #expect(hub.isBusy)
        let exitReport = hub.reports.first { $0.id == "app:grok-bot" }
        #expect(exitReport?.isWorkingNow == false)
        #expect(exitReport?.lastWorkingAt == clock)

        // 重複 absent 不延長
        let exitAt = clock
        clock = clock.addingTimeInterval(10)
        hub.tick()
        #expect(hub.reports.first { $0.id == "app:grok-bot" }?.lastWorkingAt == exitAt)

        clock = exitAt.addingTimeInterval(299)
        hub.tick()
        #expect(hub.isBusy)

        clock = exitAt.addingTimeInterval(300)
        hub.tick()
        #expect(!hub.isBusy)
        hub.stop()
    }

    @Test("V-C07-4 agents sourceReport does not double grace (300 not 600)")
    func agentsNoDoubleGrace() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "chorus-hub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let file = root.appending(path: "session.jsonl")
        try Data("{}\n".utf8).write(to: file)
        let writeTime = Date(timeIntervalSince1970: 5_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: writeTime], ofItemAtPath: file.path
        )

        var clock = writeTime.addingTimeInterval(299)
        let monitor = AgentActivityMonitor(
            sources: [ResolvedAgentLogSource(engine: "Codex", root: root)],
            processSampler: nil,
            graceSeconds: 300,
            now: { clock }
        )
        monitor.chromiumThrottleWarningOverride = false
        await monitor.refresh()
        #expect(monitor.isWorking)

        let hub = KeepAwakeSourceHub(
            agentActivity: monitor,
            orca: OrcaActivitySource(runner: FakeRunner(), workspaceCenter: NotificationCenter(), presence: FakePresence()),
            desktop: DesktopAgentSource(
                lister: StaticDesktopLister([]),
                verifier: FakeVerifier(ok: false),
                transcripts: StaticTranscriptScanner([])
            ),
            leases: KeepAwakeLeaseSource(),
            appPresence: AppPresenceSource(checker: FakeAppChecker()),
            now: { clock }
        )
        hub.configure(KeepAwakeSourceSettings(orcaEnabled: false, desktopAgentsEnabled: false))
        hub.start()
        #expect(hub.isBusy)

        clock = writeTime.addingTimeInterval(300)
        await monitor.refresh()
        hub.recompute()
        #expect(!hub.isBusy)
        hub.stop()
    }

    @Test("V-C07-5 settings opt-out removes source immediately")
    func optOutRemoves() {
        var clock = Date(timeIntervalSince1970: 6_000_000)
        let checker = FakeAppChecker()
        checker.present = true
        let presence = AppPresenceSource(checker: checker, now: { clock })
        let hub = KeepAwakeSourceHub(
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            orca: OrcaActivitySource(runner: FakeRunner(), workspaceCenter: NotificationCenter(), presence: FakePresence()),
            desktop: DesktopAgentSource(
                lister: StaticDesktopLister([]),
                verifier: FakeVerifier(ok: false),
                transcripts: StaticTranscriptScanner([])
            ),
            leases: KeepAwakeLeaseSource(wallNow: { clock }, uptimeNow: { clock.timeIntervalSince1970 }),
            appPresence: presence,
            now: { clock }
        )
        hub.agentActivity.chromiumThrottleWarningOverride = false
        hub.configure(
            KeepAwakeSourceSettings(orcaEnabled: false, desktopAgentsEnabled: false, grokBotEnabled: true)
        )
        hub.start()
        presence.refresh(notify: true)
        #expect(hub.reports.contains { $0.id == "app:grok-bot" })

        hub.configure(
            KeepAwakeSourceSettings(orcaEnabled: false, desktopAgentsEnabled: false, grokBotEnabled: false)
        )
        #expect(!hub.reports.contains { $0.id == "app:grok-bot" })
        hub.stop()
    }

    @Test("Grok default off and bundle id com.anysphere.sand")
    func grokDefaults() {
        #expect(KeepAwakeSourceSettings.default.grokBotEnabled == false)
        #expect(GrokBotPresence.bundleIDs == ["com.anysphere.sand"])
    }
}

// MARK: - Shared fakes for C07 tests

struct StaticDesktopLister: DesktopAgentProcessListing {
    var processes: [DesktopAgentProcess]
    init(_ processes: [DesktopAgentProcess]) { self.processes = processes }
    func listDesktopCandidates() -> [DesktopAgentProcess] { processes }
}

final class MutableDesktopLister: DesktopAgentProcessListing, @unchecked Sendable {
    var processes: [DesktopAgentProcess]
    init(_ processes: [DesktopAgentProcess]) { self.processes = processes }
    func listDesktopCandidates() -> [DesktopAgentProcess] { processes }
}

struct FakeVerifier: CodeSignatureVerifying {
    var ok: Bool
    func teamIdentifierMatches(pid: Int32, teamID: String) -> Bool { ok }
}

final class CountingVerifier: CodeSignatureVerifying, @unchecked Sendable {
    var ok: Bool
    private(set) var calls = 0
    init(ok: Bool) { self.ok = ok }
    func teamIdentifierMatches(pid: Int32, teamID: String) -> Bool {
        calls += 1
        return ok
    }
}

struct StaticTranscriptScanner: DesktopTranscriptScanning {
    var samples: [(id: String, mtime: Date)]
    init(_ samples: [(id: String, mtime: Date)]) { self.samples = samples }
    func latestMtimes(kind: DesktopAgentKind) -> [(id: String, mtime: Date)] { samples }
}

@Suite("C7-10 bounded conservative normalization")
struct KeepAwakeClampRegressionTests {
    @Test("More than 256 live future samples and churn never renew grace")
    func liveCapacityAndChurn() {
        let first = Date(timeIntervalSince1970: 8_000_000)
        let raw = first.addingTimeInterval(3_600)
        var cache = KeepAwakeMtimeClampCache()
        for index in 0..<600 {
            #expect(cache.stabilize(id: "live-\(index)", raw: raw, now: first) <= first)
        }
        for second in stride(from: 30, through: 600, by: 30) {
            let now = first.addingTimeInterval(Double(second))
            for index in 0..<600 {
                let normalized = cache.stabilize(id: "live-\(index)", raw: raw, now: now)
                #expect(normalized <= first)
                let report = KeepAwakeSourceReport(id: "sample", kind: .agentActivity,
                    displayName: "sample", detail: nil, isWorkingNow: false,
                    lastWorkingAt: normalized, health: .ok)
                let state = KeepAwakeBusyAggregator.evaluate([report], now: now)
                if second >= 300 { #expect(!state.isBusy) }
                #expect(state.releaseAt == nil || state.releaseAt! <= first.addingTimeInterval(300))
            }
            cache.retainIds([])
            for index in 0..<300 {
                _ = cache.stabilize(id: "churn-\(second)-\(index)", raw: raw, now: now)
            }
        }
        // Once wall time passes the raw date, the retired evidence still cannot renew.
        #expect(cache.stabilize(id: "live-0", raw: raw,
                               now: raw.addingTimeInterval(1)) <= first)
    }
}
