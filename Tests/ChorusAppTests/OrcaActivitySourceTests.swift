import AppKit
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
        let source = OrcaActivitySource(runner: runner, workspaceCenter: NotificationCenter(), presence: FakePresence())
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
        let source = OrcaActivitySource(runner: runner, workspaceCenter: NotificationCenter(), presence: FakePresence())
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
        let source = OrcaActivitySource(runner: runner, workspaceCenter: NotificationCenter(), presence: FakePresence())
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
            runner: runner, workspaceCenter: NotificationCenter(),
            presence: FakePresence(),
            normalInterval: .milliseconds(5),
            backoffInterval: .milliseconds(50)
        )
        let sleeper = ManualOrcaSleeper()
        source.sleep = { await sleeper.sleep($0) }
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
        await sleeper.releaseAll()
    }

    @Test("V-C07-2 Orca not running does not execute CLI")
    func noOrcaNoCLI() async {
        let presence = FakePresence()
        presence.running = false
        let runner = FakeRunner()
        let source = OrcaActivitySource(runner: runner, workspaceCenter: NotificationCenter(), presence: presence)
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
            runner: runner, workspaceCenter: NotificationCenter(),
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
        await source.reevaluatePresence()
        #expect(source.report.first?.lastWorkingAt == exitAt)

        clock = exitAt.addingTimeInterval(300)
        await source.reevaluatePresence()
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
        let source = OrcaActivitySource(runner: runner, workspaceCenter: NotificationCenter(), presence: FakePresence())
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }
        source.start(schedulePolling: false)

        // 不可在 @MainActor 上阻塞 waitUntilWaiting：會讓同 actor 的 poll Task 永遠排不到。
        let task = Task { await source.pollOnce() }
        await gate.waitUntilEntered()
        #expect(gate.isWaitingForTest)
        source.stop()
        #expect(source.report.isEmpty)
        source.start(schedulePolling: false)
        await source.pollOnce() // restart while the original child still owns its token
        #expect(runner.callCount == 1)
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
        let source = OrcaActivitySource(runner: runner, workspaceCenter: NotificationCenter(), presence: FakePresence())
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
        let source = OrcaActivitySource(runner: runner, workspaceCenter: NotificationCenter(), presence: FakePresence())
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
        let source = OrcaActivitySource(runner: runner, workspaceCenter: NotificationCenter(), presence: FakePresence())
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

    @Test("C7-8 scheduled retries use virtual time and launch interrupts backoff")
    func scheduledRetryAndObservers() async {
        let runner = FakeRunner()
        let source = OrcaActivitySource(runner: runner, workspaceCenter: NotificationCenter(), presence: FakePresence())
        let center = NotificationCenter()
        let sleeper = ManualOrcaSleeper()
        source.workspaceCenter = center
        source.presenceResolver = { true }
        source.cliPathResolver = { "/fake/orca" }
        source.sleep = { await sleeper.sleep($0) }
        source.start(schedulePolling: false)
        await source.pollOnce()
        await source.pollOnce()
        await source.pollOnce()
        source.rescheduleForTesting(immediate: false)
        await sleeper.waitForRequests(1)
        #expect(await sleeper.intervals == [.seconds(120)])
        #expect(runner.callCount == 3)
        await sleeper.release(0) // advance virtual retry deadline
        await sleeper.waitForRequests(2)
        #expect(runner.callCount == 4)
        runner.results = [OrcaCommandRunResult(exitCode: 0, stdout: Data(workingJSON.utf8),
                                               stderr: Data(), timedOut: false, killed: false)]
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await sleeper.waitForRequests(3)
        #expect(runner.callCount == 5)
        #expect(await sleeper.intervals.last == .seconds(30))
        #expect(source.report.first?.isWorkingNow == true)
        let queuedOldCallback = source.workspaceEventHandler()
        source.stop()
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await sleeper.releaseAll()
        source.start(schedulePolling: false)
        let previousInterval = source.lastScheduledInterval
        await queuedOldCallback().value
        #expect(source.lastScheduledInterval == previousInterval)
        #expect(runner.callCount == 5)
        // New observer lifecycle processes events; removed callbacks remain inert.
        source.presenceResolver = { false }
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        await sleeper.waitForRequests(4)
        #expect(source.report.isEmpty)
        #expect(runner.callCount == 5)
        source.stop()
        await sleeper.releaseAll()
    }

    @Test("C7-2 owns presence and locator preflight across overlap, restart and configure")
    func preflightOwnership() async {
        for locator in [false, true] {
            let gate = AsyncTestGate()
            let runner = FakeRunner()
            let source = OrcaActivitySource(runner: runner, workspaceCenter: NotificationCenter(), presence: FakePresence())
            source.presenceResolver = { true }
            source.cliPathResolver = { "/fake/orca" }
            if locator {
                source.asyncCLIPathResolver = { await gate.wait(); return "/fake/orca" }
            } else {
                source.asyncPresenceResolver = { await gate.wait(); return true }
            }
            source.start(schedulePolling: false)
            let first = Task { await source.pollOnce() }
            await gate.waitUntilEntered()
            await source.pollOnce()
            source.stop()
            source.start(schedulePolling: false)
            await source.pollOnce()
            source.configure(enabled: true, countPermissionAsWorking: false, cliPathOverride: nil)
            await source.pollOnce()
            #expect(runner.callCount == 0)
            await gate.open()
            await first.value
            #expect(source.report.isEmpty)
            await source.pollOnce()
            #expect(runner.callCount == 1)
            #expect(runner.maxConcurrent == 1)
            source.stop()
        }
    }

    @Test("C7-2 workspace rescheduling cannot overlap suspended presence/locator preflight")
    func preflightWorkspaceReschedule() async {
        for locator in [false, true] {
            let gate = AsyncTestGate()
            let sleeper = ManualOrcaSleeper()
            let runner = FakeRunner()
            let source = OrcaActivitySource(runner: runner, workspaceCenter: NotificationCenter(), presence: FakePresence())
            source.presenceResolver = { true }
            source.cliPathResolver = { "/fake/orca" }
            source.sleep = { await sleeper.sleep($0) }
            if locator {
                source.asyncCLIPathResolver = { await gate.wait(); return "/fake/orca" }
            } else {
                source.asyncPresenceResolver = { await gate.wait(); return true }
            }
            source.start(schedulePolling: false)
            let original = Task { await source.pollOnce() }
            await gate.waitUntilEntered()
            await source.workspaceEventHandler()().value
            await sleeper.waitForRequests(1)
            #expect(runner.callCount == 0)
            await gate.open()
            await original.value
            await sleeper.waitForRequests(2)
            #expect(runner.callCount == 1)
            #expect(runner.maxConcurrent == 1)
            source.stop()
            await sleeper.releaseAll()
        }
    }

    @Test("C7-8 termination while runner suspended cannot resurrect working")
    func terminationDuringFlight() async {
        var clock = Date(timeIntervalSince1970: 9_000_000)
        let gate = SyncGate()
        let runner = FakeRunner()
        let success = OrcaCommandRunResult(exitCode: 0, stdout: Data(workingJSON.utf8),
                                           stderr: Data(), timedOut: false, killed: false)
        runner.results = [success, success]
        let source = OrcaActivitySource(runner: runner, workspaceCenter: NotificationCenter(), presence: FakePresence(), now: { clock })
        let sleeper = ManualOrcaSleeper()
        source.sleep = { await sleeper.sleep($0) }
        var present = true
        source.presenceResolver = { present }
        source.cliPathResolver = { "/fake/orca" }
        source.start(schedulePolling: false)
        await source.pollOnce()
        #expect(source.report.first?.isWorkingNow == true)
        runner.gate = gate
        let task = Task { await source.pollOnce() }
        await gate.waitUntilEntered()
        clock = clock.addingTimeInterval(10)
        let exitAt = clock
        present = false
        await source.workspaceEventHandler()().value
        await source.reevaluatePresence()
        #expect(source.report.first?.isWorkingNow == false)
        #expect(source.report.first?.lastWorkingAt == exitAt)
        gate.open()
        await task.value
        #expect(source.report.first?.isWorkingNow == false)
        #expect(source.report.first?.lastWorkingAt == exitAt)
        #expect(runner.maxConcurrent == 1)
        clock = exitAt.addingTimeInterval(300)
        await source.reevaluatePresence()
        #expect(source.report.isEmpty)
        source.stop()
        await sleeper.releaseAll()
    }

    @Test("C7-3 TERM resistance, delayed reap and inherited writer cleanup use virtual time")
    func cleanupLifecycle() {
        var policy = OrcaCommandLifecycle(timeout: .seconds(5))
        #expect(policy.step(elapsed: .seconds(4), childRunning: true, drainsComplete: false) == .wait)
        #expect(policy.step(elapsed: .seconds(5), childRunning: true, drainsComplete: false) == .terminate)
        #expect(policy.step(elapsed: .seconds(6), childRunning: true, drainsComplete: false) == .kill)
        #expect(policy.step(elapsed: .seconds(60), childRunning: true, drainsComplete: true) == .wait)
        #expect(policy.step(elapsed: .seconds(61), childRunning: false, drainsComplete: false) == .wait)
        #expect(policy.step(elapsed: .seconds(62), childRunning: false, drainsComplete: false) == .finish(incomplete: true))
        #expect(policy.timedOut && policy.killed)
        var shortChild = OrcaCommandLifecycle(timeout: .seconds(5))
        #expect(shortChild.step(elapsed: .zero, childRunning: false, drainsComplete: false) == .wait)
        #expect(shortChild.step(elapsed: .milliseconds(500), childRunning: false, drainsComplete: true) == .finish(incomplete: false))
        let stderr = OrcaPipeDrain.Buffer(limit: OrcaPipeDrain.stderrCap)
        var chunks = 10
        let end = OrcaPipeDrain.drain(into: stderr) {
            guard chunks > 0 else { return .eof }
            chunks -= 1
            return .bytes(Data(repeating: 66, count: 65_536))
        }
        if case .eof = end {} else { Issue.record("heavy stderr must drain through EOF") }
        #expect(stderr.snapshot().0.count == OrcaPipeDrain.stderrCap)
    }

    @Test("C7-3 drain consumes suffix and overflow before explicit EOF")
    func nonblockingDrainCompletion() {
        for size in [200_000, 4 * 1_024 * 1_024 + 1] {
            let buffer = OrcaPipeDrain.Buffer(limit: 4 * 1_024 * 1_024)
            var remaining = size
            var eof = false
            while !eof {
                let result = OrcaPipeDrain.drain(into: buffer) {
                    if remaining == 0 { return .eof }
                    let count = min(remaining, 16_384)
                    remaining -= count
                    return .bytes(Data(repeating: 65, count: count))
                }
                if case .eof = result { eof = true }
            }
            #expect(buffer.snapshot().0.count == min(size, 4 * 1_024 * 1_024))
            #expect(buffer.snapshot().1 == (size > 4 * 1_024 * 1_024))
        }
        let buffer = OrcaPipeDrain.Buffer(limit: 8)
        if case .wouldBlock = OrcaPipeDrain.drain(into: buffer, read: { .wouldBlock }) {} else {
            Issue.record("EAGAIN must not be EOF")
        }
        if case .failed = OrcaPipeDrain.drain(into: buffer, read: { .failed }) {} else {
            Issue.record("read errors must not certify completion")
        }
    }

}

/// 同步閘門：供 utility 執行緒阻塞，測試可在 MainActor 上放開。
final class SyncGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isOpen = false
    private var isWaiting = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []

    func waitUntilEntered() async {
        await withCheckedContinuation { continuation in
            condition.lock()
            if isWaiting {
                condition.unlock()
                continuation.resume()
            } else {
                enteredWaiters.append(continuation)
                condition.unlock()
            }
        }
    }

    func enterAndWait() {
        condition.lock()
        isWaiting = true
        let waiters = enteredWaiters
        enteredWaiters = []
        for waiter in waiters { waiter.resume() }
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

/// Continuation gate: no sleeps, blocking actor waits or subprocesses.
actor AsyncTestGate {
    private var opened = false
    private var entered = false
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var blocked: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        let ready = arrivals
        arrivals = []
        for continuation in ready { continuation.resume() }
        if opened { return }
        await withCheckedContinuation { blocked.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { arrivals.append($0) }
    }
    func open() {
        opened = true
        let ready = blocked
        blocked = []
        for continuation in ready { continuation.resume() }
    }
}

actor ManualOrcaSleeper {
    private(set) var intervals: [Duration] = []
    private var pending: [Int: CheckedContinuation<Void, Never>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func sleep(_ interval: Duration) async {
        let index = intervals.count
        intervals.append(interval)
        await withCheckedContinuation { continuation in
            pending[index] = continuation
            let ready = observers.filter { $0.0 <= intervals.count }
            observers.removeAll { $0.0 <= intervals.count }
            for (_, observer) in ready { observer.resume() }
        }
    }
    func waitForRequests(_ count: Int) async {
        if intervals.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func release(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
    func releaseAll() {
        let ready = Array(pending.values)
        pending = [:]
        for continuation in ready { continuation.resume() }
    }
}
