import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("KeepAwakeSourceHub")
struct KeepAwakeSourceHubTests {
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
        tickInterval: Duration = .seconds(30)
    ) -> (KeepAwakeSourceHub, KeepAwakeLeaseSource) {
        let leaseSource = leases ?? KeepAwakeLeaseSource(
            wallNow: now,
            uptimeNow: { now().timeIntervalSince1970 }
        )
        let hub = KeepAwakeSourceHub(
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil, now: now),
            orca: OrcaActivitySource(
                runner: FakeRunner(),
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
            appPresence: AppPresenceSource(checker: FakeAppChecker(), now: now),
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

    @Test("V-C07-1 grace expiry via tick flips isBusy")
    func graceTick() async throws {
        var clock = Date(timeIntervalSince1970: 3_000_000)
        let (hub, leases) = makeHub(now: { clock }, tickInterval: .milliseconds(20))
        var flips: [Bool] = []
        hub.onBusyChanged = { flips.append(hub.isBusy) }
        hub.start()
        _ = leases.hold(id: "short", ttl: 30)
        #expect(hub.isBusy)

        // Expire lease (uptime == wall epoch in this fixture) then advance past grace.
        clock = clock.addingTimeInterval(31)
        leases.refresh()
        hub.recompute()
        #expect(hub.isBusy) // still in 300s grace

        clock = clock.addingTimeInterval(300)
        hub.recompute()
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
            orca: OrcaActivitySource(runner: FakeRunner(), presence: FakePresence()),
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
            orca: OrcaActivitySource(runner: FakeRunner(), presence: FakePresence()),
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
}

// MARK: - Shared fakes for C07 tests

struct StaticDesktopLister: DesktopAgentProcessListing {
    var processes: [DesktopAgentProcess]
    init(_ processes: [DesktopAgentProcess]) { self.processes = processes }
    func listDesktopCandidates() -> [DesktopAgentProcess] { processes }
}

struct FakeVerifier: CodeSignatureVerifying {
    var ok: Bool
    func teamIdentifierMatches(pid: Int32, teamID: String) -> Bool { ok }
}

struct StaticTranscriptScanner: DesktopTranscriptScanning {
    var samples: [(id: String, mtime: Date)]
    init(_ samples: [(id: String, mtime: Date)]) { self.samples = samples }
    func latestMtimes(kind: DesktopAgentKind) -> [(id: String, mtime: Date)] { samples }
}
