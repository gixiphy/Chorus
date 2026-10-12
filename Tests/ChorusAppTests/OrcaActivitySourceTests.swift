import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("OrcaActivitySource")
struct OrcaActivitySourceTests {
    final class FakePresence: OrcaPresenceChecking, @unchecked Sendable {
        var running = true
        func isOrcaRunning() -> Bool { running }
    }

    final class FakeRunner: OrcaCommandRunning, @unchecked Sendable {
        var results: [OrcaCommandRunResult] = []
        private(set) var callCount = 0
        private(set) var lastExecutable: String?
        private(set) var maxConcurrent = 0
        private var inFlight = 0
        var gate: SyncGate?

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            timeout: Duration,
            stdoutLimit: Int
        ) async -> OrcaCommandRunResult {
            callCount += 1
            lastExecutable = executable
            inFlight += 1
            maxConcurrent = max(maxConcurrent, inFlight)
            if let gate {
                await Task.detached { gate.enterAndWait() }.value
            }
            defer { inFlight -= 1 }
            if results.isEmpty {
                return OrcaCommandRunResult(
                    exitCode: 1, stdout: Data(), stderr: Data(), timedOut: false, killed: false
                )
            }
            return results.removeFirst()
        }
    }

    private let workingJSON = """
    {"ok":true,"result":{"worktrees":[{"worktreeId":"w1","status":"working"}],"truncated":false}}
    """
    private let permissionJSON = """
    {"ok":true,"result":{"worktrees":[{"worktreeId":"w1","status":"permission"}],"truncated":false}}
    """

    @Test("V-C07-2 missing CLI → unavailable")
    func missingCLI() async {
        let runner = FakeRunner()
        let source = OrcaActivitySource(runner: runner, presence: FakePresence())
        source.cliPathResolver = { nil }
        source.configure(enabled: true, countPermissionAsWorking: true, cliPathOverride: nil)
        source.start(schedulePolling: false)
        await source.pollOnce()
        #expect(source.report.count == 1)
        #expect(source.report.first?.health == .unavailable(reason: "找不到 orca CLI"))
        #expect(runner.callCount == 0)
        source.stop()
    }

    @Test("V-C07-2 timeout marks degraded and runner reports kill path")
    func timeoutDegraded() async {
        let runner = FakeRunner()
        runner.results = [
            OrcaCommandRunResult(
                exitCode: nil, stdout: Data(), stderr: Data(), timedOut: true, killed: true
            ),
        ]
        let source = OrcaActivitySource(runner: runner, presence: FakePresence())
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }
        source.fallbackCapability = .unverified
        source.start(schedulePolling: false)
        await source.pollOnce()
        guard case let .degraded(reason) = source.report.first?.health else {
            Issue.record("expected degraded, got \(String(describing: source.report.first?.health))")
            return
        }
        #expect(reason.contains("逾時") || reason.contains("失敗"))
        #expect(!reason.contains("改用行程偵測"))
        source.stop()
    }

    @Test("C7-7 TTY off / unverified must not claim fallback in effect")
    func truthfulFallbackHealth() async {
        let fail = OrcaCommandRunResult(
            exitCode: 1, stdout: Data(), stderr: Data(), timedOut: false, killed: false
        )
        let runner = FakeRunner()
        runner.results = [fail, fail, fail]
        let source = OrcaActivitySource(runner: runner, presence: FakePresence())
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }
        source.start(schedulePolling: false)

        source.fallbackCapability = .unavailable
        await source.pollOnce()
        guard case let .degraded(offReason) = source.report.first?.health else {
            Issue.record("expected degraded")
            return
        }
        #expect(!offReason.contains("改用行程偵測"))
        #expect(!offReason.contains("行程偵測"))

        source.fallbackCapability = .unverified
        await source.pollOnce()
        guard case let .degraded(unverifiedReason) = source.report.first?.health else {
            Issue.record("expected degraded")
            return
        }
        #expect(!unverifiedReason.contains("改用行程偵測"))

        source.fallbackCapability = .active
        await source.pollOnce()
        guard case let .degraded(activeReason) = source.report.first?.health else {
            Issue.record("expected degraded")
            return
        }
        #expect(activeReason.contains("改用行程偵測"))
        source.stop()
    }

    @Test("V-C07-2 three failures schedule 120s; success restores 30s")
    func backoffThenRecover() async {
        let runner = FakeRunner()
        let fail = OrcaCommandRunResult(
            exitCode: 1, stdout: Data(), stderr: Data(), timedOut: false, killed: false
        )
        runner.results = [fail, fail, fail]
        let source = OrcaActivitySource(
            runner: runner,
            presence: FakePresence(),
            normalInterval: .milliseconds(5),
            backoffInterval: .milliseconds(50)
        )
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }
        source.start(schedulePolling: false)
        await source.pollOnce()
        await source.pollOnce()
        await source.pollOnce()
        #expect(runner.callCount == 3)
        source.rescheduleForTesting(immediate: false)
        #expect(source.lastScheduledInterval == .milliseconds(50))

        runner.results = [
            OrcaCommandRunResult(
                exitCode: 0,
                stdout: Data(workingJSON.utf8),
                stderr: Data(),
                timedOut: false,
                killed: false
            ),
        ]
        await source.pollOnce()
        #expect(source.report.first?.isWorkingNow == true)
        source.rescheduleForTesting(immediate: false)
        #expect(source.lastScheduledInterval == .milliseconds(5))
        source.stop()
    }

    @Test("V-C07-2 Orca not running does not execute CLI")
    func noOrcaNoCLI() async {
        let presence = FakePresence()
        presence.running = false
        let runner = FakeRunner()
        let source = OrcaActivitySource(runner: runner, presence: presence)
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }
        source.start(schedulePolling: false)
        await source.pollOnce()
        #expect(runner.callCount == 0)
        #expect(source.report.isEmpty)
        source.stop()
    }

    @Test("C7-8 absence keeps one grace then removes report")
    func absenceGraceThenClear() async {
        var clock = Date(timeIntervalSince1970: 9_000_000)
        let presence = FakePresence()
        let runner = FakeRunner()
        runner.results = [
            OrcaCommandRunResult(
                exitCode: 0,
                stdout: Data(workingJSON.utf8),
                stderr: Data(),
                timedOut: false,
                killed: false
            ),
        ]
        let source = OrcaActivitySource(
            runner: runner,
            presence: presence,
            now: { clock },
            graceSeconds: 300
        )
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }
        source.start(schedulePolling: false)
        await source.pollOnce()
        #expect(source.report.first?.isWorkingNow == true)

        presence.running = false
        let exitAt = clock
        await source.pollOnce()
        #expect(source.report.first?.isWorkingNow == false)
        #expect(source.report.first?.lastWorkingAt == exitAt)

        clock = exitAt.addingTimeInterval(10)
        source.refreshAbsenceGraceIfNeeded()
        #expect(source.report.first?.lastWorkingAt == exitAt)

        clock = exitAt.addingTimeInterval(300)
        source.refreshAbsenceGraceIfNeeded()
        #expect(source.report.isEmpty)
        source.stop()
    }

    @Test("C7-2 stop during flight discards late result; max one child")
    func stopDiscardsLateFlight() async {
        let runner = FakeRunner()
        let gate = SyncGate()
        runner.gate = gate
        runner.results = [
            OrcaCommandRunResult(
                exitCode: 0,
                stdout: Data(workingJSON.utf8),
                stderr: Data(),
                timedOut: false,
                killed: false
            ),
        ]
        let source = OrcaActivitySource(runner: runner, presence: FakePresence())
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }
        source.start(schedulePolling: false)

        // 不可在 @MainActor 上阻塞 waitUntilWaiting：會讓同 actor 的 poll Task 永遠排不到。
        let task = Task { await source.pollOnce() }
        for _ in 0..<100 {
            if gate.isWaitingForTest { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(gate.isWaitingForTest)
        source.stop()
        #expect(source.report.isEmpty)
        gate.open()
        await task.value
        #expect(source.report.isEmpty)
        #expect(runner.maxConcurrent == 1)

        // restart while ensuring old completion cannot resurrect
        source.start(schedulePolling: false)
        runner.results = [
            OrcaCommandRunResult(
                exitCode: 0,
                stdout: Data(workingJSON.utf8),
                stderr: Data(),
                timedOut: false,
                killed: false
            ),
        ]
        await source.pollOnce()
        #expect(source.report.first?.isWorkingNow == true)
        #expect(runner.maxConcurrent == 1)
        source.stop()
    }

    @Test("C4-5 qualityWarning → degraded health, keeps working evidence")
    func qualityWarningDegradedKeepsWorking() async {
        let mixed = """
        {"ok":true,"result":{"worktrees":[\
        {"worktreeId":"w1","status":"working"},\
        {"worktreeId":"w2","status":"thinking"}\
        ],"truncated":false}}
        """
        let runner = FakeRunner()
        runner.results = [
            OrcaCommandRunResult(
                exitCode: 0,
                stdout: Data(mixed.utf8),
                stderr: Data(),
                timedOut: false,
                killed: false
            ),
        ]
        let source = OrcaActivitySource(runner: runner, presence: FakePresence())
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }
        source.start(schedulePolling: false)
        await source.pollOnce()
        #expect(source.report.first?.isWorkingNow == true)
        #expect(source.report.first?.lastWorkingAt != nil)
        guard case let .degraded(reason) = source.report.first?.health else {
            Issue.record("expected degraded, got \(String(describing: source.report.first?.health))")
            return
        }
        #expect(reason == OrcaActivityPlanner.unknownStatusWarning)
        source.stop()
    }

    @Test("C7-3 overflowed runner result marks degraded without real child")
    func stdoutOverflowViaFake() async {
        let runner = FakeRunner()
        runner.results = [
            OrcaCommandRunResult(
                exitCode: nil,
                stdout: Data(repeating: 0x41, count: 64),
                stderr: Data(),
                timedOut: true,
                killed: false,
                stdoutOverflowed: true
            ),
        ]
        let source = OrcaActivitySource(runner: runner, presence: FakePresence())
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }
        source.fallbackCapability = .unverified
        source.start(schedulePolling: false)
        await source.pollOnce()
        guard case let .degraded(reason) = source.report.first?.health else {
            Issue.record("expected degraded")
            return
        }
        #expect(reason.contains("stdout") || reason.contains("上限"))
        #expect(source.report.first?.isWorkingNow == false)
        source.stop()
    }

    @Test("C7-3 OrcaPipeDrain.Buffer caps and marks overflow")
    func pipeDrainBufferBounds() {
        let buffer = OrcaPipeDrain.Buffer(limit: 8)
        buffer.append(Data("abcdef".utf8))
        var snap = buffer.snapshot()
        #expect(snap.0 == Data("abcdef".utf8))
        #expect(snap.1 == false)

        buffer.append(Data("ghijkl".utf8))
        snap = buffer.snapshot()
        #expect(snap.0.count == 8)
        #expect(snap.0 == Data("abcdefgh".utf8))
        #expect(snap.1 == true)

        // 已 overflow 後繼續 append 不增長
        buffer.append(Data("zzz".utf8))
        #expect(buffer.snapshot().0.count == 8)
    }

    @Test("V-C07-2 permission setting honored")
    func permissionSetting() async {
        let runner = FakeRunner()
        runner.results = [
            OrcaCommandRunResult(
                exitCode: 0,
                stdout: Data(permissionJSON.utf8),
                stderr: Data(),
                timedOut: false,
                killed: false
            ),
            OrcaCommandRunResult(
                exitCode: 0,
                stdout: Data(permissionJSON.utf8),
                stderr: Data(),
                timedOut: false,
                killed: false
            ),
        ]
        let source = OrcaActivitySource(runner: runner, presence: FakePresence())
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }

        source.configure(enabled: true, countPermissionAsWorking: true, cliPathOverride: nil)
        source.start(schedulePolling: false)
        await source.pollOnce()
        #expect(source.report.first?.isWorkingNow == true)

        source.configure(enabled: true, countPermissionAsWorking: false, cliPathOverride: nil)
        await source.pollOnce()
        #expect(source.report.first?.isWorkingNow == false)
        source.stop()
    }

}

/// 同步閘門：供 utility 執行緒阻塞，測試可在 MainActor 上放開。
final class SyncGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var isWaiting = false

    func enterAndWait() {
        condition.lock()
        isWaiting = true
        condition.broadcast()
        while !isOpen {
            condition.wait()
        }
        condition.unlock()
    }

    var isWaitingForTest: Bool {
        condition.lock()
        defer { condition.unlock() }
        return isWaiting
    }

    func open() {
        condition.lock()
        isOpen = true
        condition.broadcast()
        condition.unlock()
    }
}
