import ChorusCore
import Foundation
import Synchronization
import Testing
@testable import Chorus

/// Injectable evidence-sleep gate for PERF1-R3/R7 (Mutex-safe from async).
final class PERF1EvidenceSleepGate: Sendable {
    private struct State {
        var conts: [UUID: CheckedContinuation<Void, Never>] = [:]
        var delays: [TimeInterval] = []
        var cancelled = false
    }
    private let state = Mutex(State())

    func sleep(_ delay: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
          await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.cancelled || Task.isCancelled {
                    return true
                }
                s.delays.append(delay)
                s.conts[id] = cont
                return false
            }
            if resumeNow { cont.resume() }
          }
        } onCancel: {
            self.state.withLock { $0.conts.removeValue(forKey: id) }?.resume()
        }
    }

    func releaseOne() {
        let cont = state.withLock { s -> CheckedContinuation<Void, Never>? in
            guard let id = s.conts.keys.first else { return nil }
            return s.conts.removeValue(forKey: id)
        }
        cont?.resume()
    }

    /// PERF1-R7 round3: cancel all waiters so suites cannot leak sleeping retries.
    func cancelAll() {
        let pending = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.cancelled = true
            let c = Array(s.conts.values)
            s.conts.removeAll()
            return c
        }
        for cont in pending { cont.resume() }
    }

    var delayCount: Int { state.withLock { $0.delays.count } }
    var recordedDelays: [TimeInterval] { state.withLock { $0.delays } }
    var waiterCount: Int { state.withLock { $0.conts.count } }
}

@MainActor
@Suite("LidSleepGuardController")
struct LidSleepGuardControllerTests {
    @MainActor
    final class RecoveryGate {
        var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func wait() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    if released || Task.isCancelled { $0.resume() }
                    else { continuation = $0 }
                }
            } onCancel: { Task { @MainActor in self.release() } }
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }

    @Test("V01R3 older detect failure cannot replace newer detect evidence", .timeLimit(.minutes(1)))
    func newerDetectionSupersedesOldStatusFailure() async throws {
        let helper = FakeHelper()
        helper.sleepDisabled = true
        let gate = RecoveryGate()
        defer { gate.release() }
        helper.statusHandler = {
            if helper.statusCalls == 1 {
                await gate.wait()
                throw PowerHelperClientError.remote("oldFailure")
            }
            return helper.makeStatus()
        }
        let (controller, _, _, _) = makeController(helper: helper, probe: { true })
        defer { controller.shutdown() }
        let old = Task { await controller.detectLeftover() }
        defer { old.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while gate.continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(gate.continuation != nil)
        await controller.detectLeftover()
        #expect(controller.leftover == .foreign)
        gate.release()
        await old.value
        #expect(controller.leftover == .foreign)
    }

    @Test("V01R3 older probe cannot clear newer recovery classification", .timeLimit(.minutes(1)))
    func newerDetectionSupersedesOldProbe() async throws {
        let helper = FakeHelper()
        helper.sleepDisabled = true
        let gate = RecoveryGate()
        defer { gate.release() }
        var probes = 0
        let (controller, _, _, _) = makeController(helper: helper, probe: {
            probes += 1
            if probes == 1 { await gate.wait(); return false }
            return true
        })
        defer { controller.shutdown() }
        let old = Task { await controller.detectLeftover() }
        let deadline = ContinuousClock.now + .seconds(2)
        while gate.continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(gate.continuation != nil)
        await controller.detectLeftover()
        #expect(controller.leftover == .foreign)
        gate.release()
        await old.value
        #expect(controller.leftover == .foreign)
    }

    final class FakeHelper: PowerHelperClienting {
        var availability: LidHelperAvailability = .ready
        var hasEnabledServiceEvidence: Bool { availability == .ready || availability == .connecting }
        var onAvailabilityChange: (() -> Void)?
        var sleepDisabled = false
        var setByHelper = false
        var callerIsHolder = false
        var holderCount = 0
        var otherUsersHolding = false
        var forcedOffReason: String?
        var recoveryBlocked = false
        var pendingRestore = false
        var persistRetryNeeded = false
        /// When true, status() alone promotes `.connecting` → `.ready` (C8-1).
        var promoteOnStatus = false
        var setCalls: [Bool] = []
        var statusCalls = 0
        var syncCalls: [(Bool, TimeInterval)] = []
        var refreshCalls: [PowerHelperRefreshReason] = []
        var failNextSet = false
        var hangSet = false
        var hangSync = false
        var setDelay: Duration = .seconds(0)
        /// After a successful set(true), next status/set returns externalInterference evidence.
        var tripExternalInterferenceAfterArm = false
        /// C8-2: status() throws (lost evidence) after a failed set.
        var failStatus = false
        /// C8-2: next status() surfaces externalInterference without a successful set reply.
        var injectInterferenceOnStatus = false
        var statusHandler: (() async throws -> PowerHelperStatus)?
        var failRelease = false
        /// Optional SM mapping for refreshAvailability (PERF1-R3/R7).
        var refreshHandler: ((PowerHelperRefreshReason) async -> Void)?
        var beforeSet: ((Bool) async -> Void)?
        var unregisterHandler: (() async -> Void)?

        func refreshAvailability(reason: PowerHelperRefreshReason) async {
            refreshCalls.append(reason)
            if let refreshHandler {
                await refreshHandler(reason)
            }
        }
        func register() async throws {}
        func unregister() async throws {
            await unregisterHandler?()
            availability = .notRegistered
        }
        func openApprovalSettings() {}

        func setSleepDisabled(_ on: Bool) async throws -> PowerHelperStatus {
            setCalls.append(on)
            await beforeSet?(on)
            if !on, failRelease { throw PowerHelperClientError.remote("restoreFailed") }
            if hangSet {
                try await Task.sleep(for: .seconds(30))
            }
            if setDelay > .zero {
                try await Task.sleep(for: setDelay)
            }
            if failNextSet {
                failNextSet = false
                throw PowerHelperClientError.remote("refused")
            }
            if on, tripExternalInterferenceAfterArm, sleepDisabled {
                // Heartbeat / re-acquire after external cleared holders.
                sleepDisabled = false
                setByHelper = false
                callerIsHolder = false
                holderCount = 0
                forcedOffReason = "externalInterference"
                return makeStatus()
            }
            sleepDisabled = on
            setByHelper = on || setByHelper
            callerIsHolder = on
            holderCount = on ? 1 : 0
            if !on { setByHelper = false }
            return makeStatus()
        }

        func status() async throws -> PowerHelperStatus {
            statusCalls += 1
            if let statusHandler { return try await statusHandler() }
            if failStatus {
                throw PowerHelperClientError.remote("statusLost")
            }
            if injectInterferenceOnStatus {
                injectInterferenceOnStatus = false
                injectExternalInterference()
            }
            if promoteOnStatus, case .connecting = availability {
                availability = .ready
                onAvailabilityChange?()
            }
            return makeStatus()
        }

        func setSleepDisabledSynchronously(_ on: Bool, timeout: TimeInterval) -> Bool {
            syncCalls.append((on, timeout))
            if hangSync {
                // Client-side timeout path: return false within the allowance.
                Thread.sleep(forTimeInterval: min(0.05, timeout))
                return false
            }
            sleepDisabled = on
            callerIsHolder = on
            holderCount = on ? 1 : 0
            if !on { setByHelper = false }
            return true
        }

        func makeStatus() -> PowerHelperStatus {
            PowerHelperStatus(
                helperBuild: "1",
                sleepDisabled: sleepDisabled,
                setByHelper: setByHelper,
                holderCount: holderCount,
                callerIsHolder: callerIsHolder,
                otherUsersHolding: otherUsersHolding,
                lastForcedOffReason: forcedOffReason,
                recoveryBlocked: recoveryBlocked,
                pendingRestore: pendingRestore,
                persistRetryNeeded: persistRetryNeeded
            )
        }

        func injectExternalInterference() {
            sleepDisabled = false
            setByHelper = false
            callerIsHolder = false
            holderCount = 0
            forcedOffReason = "externalInterference"
        }
    }

    final class FakeLid: LidStateObserving {
        var isClosed: Bool? {
            switch reading {
            case .closed: return true
            case .open: return false
            case .noLid, .unknown: return nil
            }
        }
        var reading: LidClosedReading = .open
        var onChange: (() -> Void)?
        private(set) var pollingEnabled = false
        private(set) var started = false

        func start() { started = true }
        func stop() { started = false }
        func setPollingEnabled(_ enabled: Bool) { pollingEnabled = enabled }

        func publish(_ next: LidClosedReading) {
            reading = next
            onChange?()
        }
    }

    final class FakeNotifier: KeepAwakeNotifying {
        var armed: [[KeepAwakeSourceReport]] = []
        var released: [(LidBlockReason?, Bool)] = []
        var leftoverRestored = 0
        var leftoverForeign = 0
        var leftoverRecovery = 0
        var forcedOff: [String] = []
        var helperApproval = 0

        func notifyPowerFloorPaused(_ state: PowerFloorState) {}
        func notifyLidGuardArmed(sources: [KeepAwakeSourceReport]) { armed.append(sources) }
        func notifyLidGuardReleased(reason: LidBlockReason?, lidClosed: Bool) {
            released.append((reason, lidClosed))
        }
        func notifyLidGuardHelperNeedsApproval() { helperApproval += 1 }
        func notifyLeftoverRestored() { leftoverRestored += 1 }
        func notifyLeftoverForeign() { leftoverForeign += 1 }
        func notifyLeftoverRecoveryNeeded() { leftoverRecovery += 1 }
        func notifyHelperForcedOff(reason: String) { forcedOff.append(reason) }
    }

    private func makeSettings() -> SettingsStore {
        SettingsStore(defaults: UserDefaults(suiteName: "lid-c08-\(UUID().uuidString)")!)
    }

    private func makeController(
        helper: FakeHelper = FakeHelper(),
        lid: FakeLid = FakeLid(),
        notifier: FakeNotifier = FakeNotifier(),
        settings: SettingsStore? = nil,
        now: @escaping () -> Double = { 1_000 },
        e2e: Bool = false,
        probe: @escaping () async -> Bool? = { nil },
        sessionStore: LidClosedSessionStore = LidClosedSessionStore(
            suiteName: "lid-session-\(UUID().uuidString)"
        ),
        heartbeat: TimeInterval = 0.15,
        evidenceSleep: @escaping (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(for: .seconds(seconds))
        }
    ) -> (LidSleepGuardController, FakeHelper, FakeLid, FakeNotifier) {
        let store = settings ?? makeSettings()
        if settings == nil {
            store.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        }
        let controller = LidSleepGuardController(
            settings: store,
            helper: helper,
            lid: lid,
            notifier: notifier,
            now: now,
            e2eNamedInstance: e2e,
            sessionStore: sessionStore,
            sleepDisabledProbe: probe,
            heartbeatInterval: heartbeat,
            evidenceSleep: evidenceSleep
        )
        return (controller, helper, lid, notifier)
    }

    private func busyState(_ id: String = "lease:t1") -> KeepAwakeBusyState {
        KeepAwakeBusyState(
            isBusy: true,
            contributing: [
                KeepAwakeSourceReport(
                    id: id, kind: .lease, displayName: "t1", detail: nil,
                    isWorkingNow: true, lastWorkingAt: Date(), health: .ok
                )
            ],
            releaseAt: nil
        )
    }

    private func acPower(thermal: ProcessInfo.ThermalState = .nominal) -> PowerSnapshot {
        PowerSnapshot(hasInternalBattery: true, onBattery: false, percent: 80, thermal: thermal)
    }

    @Test("V01 resumeAfterPause clears pause and reacquires after reevaluation", .timeLimit(.minutes(1)))
    func resumeAfterPauseReevaluates() async throws {
        let (controller, helper, _, _) = makeController(now: { 1_000 }, heartbeat: 3_600)
        defer { controller.shutdown() }
        let changes = AsyncStream<Void>.makeStream()
        defer { changes.continuation.finish() }
        controller.onChange = { changes.continuation.yield(()) }
        var iterator = changes.stream.makeAsyncIterator()

        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        while !controller.isActuallyHoldingSleepDisabled {
            let event = await iterator.next()
            _ = try #require(event)
        }

        controller.pauseForOneHour()
        #expect(controller.state.userPausedUntil == 4_600)
        #expect(controller.phase == .blocked(.userPaused(untilUptime: 4_600)))
        #expect(!controller.wantsSleepDisabled)
        while controller.helperStatus?.callerIsHolder != false {
            let event = await iterator.next()
            _ = try #require(event)
        }
        #expect(helper.setCalls == [true, false])

        controller.resumeAfterPause()
        #expect(controller.state.userPausedUntil == nil)
        try #require(controller.phase == .armed)
        try #require(controller.wantsSleepDisabled)
        while !controller.isActuallyHoldingSleepDisabled {
            let event = await iterator.next()
            _ = try #require(event)
        }
        #expect(helper.setCalls == [true, false, true])
    }

    @Test("V01 resumeAfterPause reevaluates thermal safety instead of bypassing it")
    func resumeAfterPausePreservesSafetyGates() {
        let (controller, helper, _, _) = makeController(now: { 1_000 }, heartbeat: 3_600)
        defer { controller.shutdown() }
        controller.pauseForOneHour()
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(thermal: .serious), existingFloor: .percent20
        )
        #expect(controller.phase == .blocked(.userPaused(untilUptime: 4_600)))

        controller.resumeAfterPause()
        #expect(controller.state.userPausedUntil == nil)
        #expect(controller.phase == .blocked(.thermal))
        #expect(!controller.wantsSleepDisabled)
        #expect(helper.setCalls.isEmpty)
    }

    @Test("V01 resumeAfterPause without a pause does not reevaluate or publish")
    func resumeAfterPauseWithoutPauseIsNoOp() {
        let (controller, helper, _, _) = makeController(now: { 1_000 }, heartbeat: 3_600)
        defer { controller.shutdown() }
        controller.update(
            agentModeActive: true, busy: .init(isBusy: false, contributing: [], releaseAt: nil),
            power: acPower(), existingFloor: .percent20
        )
        #expect(controller.phase == .idle)
        #expect(controller.state.userPausedUntil == nil)
        var publications = 0
        controller.onChange = { publications += 1 }
        let stateBefore = controller.state
        let statusCallsBefore = helper.statusCalls

        controller.resumeAfterPause()
        #expect(controller.state == stateBefore)
        #expect(!controller.wantsSleepDisabled)
        #expect(publications == 0)
        #expect(helper.setCalls.isEmpty)
        #expect(helper.statusCalls == statusCallsBefore)
    }

    @Test("idle→armed calls set(true) once and heartbeats (V-C08-1)")
    func armsAndHeartbeats() async throws {
        let (controller, helper, _, _) = makeController(heartbeat: 0.12)
        defer { controller.shutdown() }

        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        let armDeadline = ContinuousClock.now + .seconds(2)
        while helper.setCalls.filter({ $0 }).isEmpty, ContinuousClock.now < armDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(helper.setCalls.filter({ $0 }).count == 1)
        #expect(controller.wantsSleepDisabled)

        let beatDeadline = ContinuousClock.now + .seconds(2)
        while helper.setCalls.filter({ $0 }).count < 2, ContinuousClock.now < beatDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(helper.setCalls.filter({ $0 }).count >= 2)
    }

    @Test("armed→idle calls set(false) and stops heartbeat (V-C08-1)")
    func releasesAndStopsHeartbeat() async throws {
        let (controller, helper, _, _) = makeController(heartbeat: 0.12)
        defer { controller.shutdown() }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        let armDeadline = ContinuousClock.now + .seconds(2)
        while helper.setCalls.filter({ $0 }).isEmpty, ContinuousClock.now < armDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }

        controller.update(
            agentModeActive: true,
            busy: .init(isBusy: false, contributing: [], releaseAt: nil),
            power: acPower(),
            existingFloor: .percent20
        )
        let releaseDeadline = ContinuousClock.now + .seconds(2)
        while !helper.setCalls.contains(false), ContinuousClock.now < releaseDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(helper.setCalls.contains(false))
        let truesAfterRelease = helper.setCalls.filter { $0 }.count

        try await Task.sleep(for: .milliseconds(400))
        #expect(helper.setCalls.filter { $0 }.count == truesAfterRelease)
    }

    @Test("set(true) failure → unavailable(.error) and retries with backoff (V-C08-1)")
    func setFailureRetries() async throws {
        let helper = FakeHelper()
        helper.failNextSet = true
        let (controller, _, _, _) = makeController(helper: helper)
        defer { controller.shutdown() }

        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        var sawUnavailable = false
        let failDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < failDeadline {
            if case .unavailable(.error) = controller.phase {
                sawUnavailable = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawUnavailable)

        // PERF-1 evidence retry first delay is 5s.
        let retryDeadline = ContinuousClock.now + .seconds(7)
        while helper.setCalls.filter({ $0 }).count < 2, ContinuousClock.now < retryDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(helper.setCalls.filter({ $0 }).count >= 2)
    }

    @Test("forcedOffReason notifies once (V-C08-1)")
    func forcedOffNotifies() async throws {
        let helper = FakeHelper()
        let notifier = FakeNotifier()
        let (controller, _, _, _) = makeController(helper: helper, notifier: notifier)
        defer { controller.shutdown() }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        let armDeadline = ContinuousClock.now + .seconds(2)
        while helper.setCalls.isEmpty, ContinuousClock.now < armDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        helper.forcedOffReason = "thermal critical"
        await controller.refreshFromHelper()
        #expect(notifier.forcedOff == ["thermal critical"])
        await controller.refreshFromHelper()
        #expect(notifier.forcedOff.count == 1)
    }

    @Test("shutdown sync set(false) returns within 1s when helper hangs (V-C08-2)")
    func shutdownBounded() async throws {
        let helper = FakeHelper()
        helper.hangSync = true
        let (controller, _, _, _) = makeController(helper: helper)
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        let start = ContinuousClock.now
        controller.shutdown()
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1.5))
        #expect(helper.syncCalls.contains(where: { $0.0 == false && $0.1 <= 1.0 }))
    }

    @Test("leftover branches cover §6.6 (V-C08-3)")
    func leftoverBranches() async throws {
        // Own residual
        do {
            let helper = FakeHelper()
            helper.sleepDisabled = true
            helper.setByHelper = true
            helper.holderCount = 0
            helper.callerIsHolder = false
            let notifier = FakeNotifier()
            let (controller, _, _, _) = makeController(
                helper: helper, notifier: notifier, probe: { true }
            )
            defer { controller.shutdown() }
            await controller.detectLeftover()
            let deadline = ContinuousClock.now + .seconds(2)
            while notifier.leftoverRestored == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(notifier.leftoverRestored == 1)
            #expect(controller.leftover == nil)
            // V1-4: direct set(false) only — no acquire-as-repair.
            #expect(helper.setCalls == [false])
        }

        // Foreign
        do {
            let helper = FakeHelper()
            helper.sleepDisabled = true
            helper.setByHelper = false
            helper.holderCount = 0
            let notifier = FakeNotifier()
            let (controller, _, _, _) = makeController(
                helper: helper, notifier: notifier, probe: { true }
            )
            defer { controller.shutdown() }
            await controller.detectLeftover()
            #expect(controller.leftover == .foreign)
            #expect(notifier.leftoverForeign == 1)
        }

        // Other holders
        do {
            let helper = FakeHelper()
            helper.sleepDisabled = true
            helper.holderCount = 1
            helper.callerIsHolder = false
            helper.otherUsersHolding = true
            let (controller, _, _, _) = makeController(helper: helper, probe: { true })
            defer { controller.shutdown() }
            await controller.detectLeftover()
            #expect(controller.leftover == .otherUserHolding)
        }

        // Helper unavailable
        do {
            let helper = FakeHelper()
            helper.availability = .notRegistered
            struct Boom: Error {}
            final class FailingHelper: PowerHelperClienting {
                var availability: LidHelperAvailability = .notRegistered
                var onAvailabilityChange: (() -> Void)?
                func refreshAvailability(reason: PowerHelperRefreshReason) async {}
                func register() async throws {}
                func unregister() async throws {}
                func openApprovalSettings() {}
                func setSleepDisabled(_ on: Bool) async throws -> PowerHelperStatus {
                    throw Boom()
                }
                func status() async throws -> PowerHelperStatus { throw Boom() }
                func setSleepDisabledSynchronously(_ on: Bool, timeout: TimeInterval) -> Bool {
                    false
                }
            }
            let failing = FailingHelper()
            let store = makeSettings()
            store.keepAwakeLidGuard = LidSleepSettings(enabled: true)
            let controller = LidSleepGuardController(
                settings: store,
                helper: failing,
                lid: FakeLid(),
                notifier: FakeNotifier(),
                now: { 1_000 },
                e2eNamedInstance: false,
                sessionStore: LidClosedSessionStore(suiteName: "leftover-unk-\(UUID().uuidString)"),
                sleepDisabledProbe: { true }
            )
            defer { controller.shutdown() }
            await controller.detectLeftover()
            #expect(controller.leftover == .unknownOwner)
        }
    }

    @Test("armed notification throttled once per busy period / 30min (V-C08-4 / C8-5)")
    func armedThrottle() async throws {
        var time = 1_000.0
        let helper = FakeHelper()
        let notifier = FakeNotifier()
        let (controller, _, _, _) = makeController(
            helper: helper, notifier: notifier, now: { time }
        )
        defer { controller.shutdown() }

        controller.update(
            agentModeActive: true, busy: busyState("a"), power: acPower(), existingFloor: .percent20
        )
        let deadline = ContinuousClock.now + .seconds(2)
        while notifier.armed.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(notifier.armed.count == 1)

        // Same busy period — no second toast.
        controller.update(
            agentModeActive: true, busy: busyState("a"), power: acPower(), existingFloor: .percent20
        )
        await controller.refreshFromHelper()
        #expect(notifier.armed.count == 1)

        // Within 30 min even after busy gap — still throttled.
        controller.update(
            agentModeActive: true,
            busy: .init(isBusy: false, contributing: [], releaseAt: nil),
            power: acPower(),
            existingFloor: .percent20
        )
        time += 60
        controller.update(
            agentModeActive: true, busy: busyState("b"), power: acPower(), existingFloor: .percent20
        )
        try await Task.sleep(for: .milliseconds(200))
        #expect(notifier.armed.count == 1)

        // After 30 minutes — allowed again.
        time += 30 * 60 + 1
        controller.update(
            agentModeActive: true,
            busy: .init(isBusy: false, contributing: [], releaseAt: nil),
            power: acPower(),
            existingFloor: .percent20
        )
        try await Task.sleep(for: .milliseconds(100))
        controller.update(
            agentModeActive: true, busy: busyState("c"), power: acPower(), existingFloor: .percent20
        )
        let again = ContinuousClock.now + .seconds(2)
        while notifier.armed.count < 2, ContinuousClock.now < again {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(notifier.armed.count == 2)
    }

    @Test("C8-1 connecting helper handshakes via status() then arms")
    func connectingHandshakeArms() async throws {
        let helper = FakeHelper()
        helper.availability = .connecting
        helper.promoteOnStatus = true
        let (controller, _, _, _) = makeController(helper: helper, heartbeat: 60)
        defer { controller.shutdown() }

        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        let deadline = ContinuousClock.now + .seconds(3)
        while helper.setCalls.filter({ $0 }).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(helper.statusCalls >= 1)
        #expect(helper.availability == .ready)
        #expect(helper.setCalls.filter({ $0 }).count >= 1)
        #expect(controller.wantsSleepDisabled)
    }

    @Test("C8-1 E2E named instance never handshakes")
    func e2eNoHandshake() async throws {
        let helper = FakeHelper()
        helper.availability = .connecting
        helper.promoteOnStatus = true
        let (controller, _, _, _) = makeController(helper: helper, e2e: true)
        defer { controller.shutdown() }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        try await Task.sleep(for: .milliseconds(150))
        #expect(helper.statusCalls == 0)
        #expect(helper.setCalls.isEmpty)
    }

    @Test("C8-2 externalInterference latches — no later set(true)")
    func externalInterferenceLatches() async throws {
        let helper = FakeHelper()
        let notifier = FakeNotifier()
        let (controller, _, _, _) = makeController(
            helper: helper, notifier: notifier, heartbeat: 0.12
        )
        defer { controller.shutdown() }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        let armDeadline = ContinuousClock.now + .seconds(2)
        while !controller.isActuallyHoldingSleepDisabled, ContinuousClock.now < armDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.isActuallyHoldingSleepDisabled)
        let truesBefore = helper.setCalls.filter({ $0 }).count

        helper.injectExternalInterference()
        await controller.refreshFromHelper()
        #expect(notifier.forcedOff.contains("externalInterference"))
        #expect(!controller.isActuallyHoldingSleepDisabled)

        // Multiple heartbeat intervals must not re-compete with set(true).
        try await Task.sleep(for: .milliseconds(500))
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        try await Task.sleep(for: .milliseconds(400))
        #expect(helper.setCalls.filter({ $0 }).count == truesBefore)
        if case let .unavailable(.error(msg)) = controller.phase {
            #expect(msg == "externalInterference")
        } else {
            Issue.record("expected unavailable(externalInterference), got \(controller.phase)")
        }
    }

    @Test("C8-2 failed heartbeat + interference on status — no reacquire before latch")
    func failedHeartbeatProbesEvidenceBeforeReacquire() async throws {
        let helper = FakeHelper()
        let notifier = FakeNotifier()
        let (controller, _, _, _) = makeController(
            helper: helper, notifier: notifier, heartbeat: 0.12
        )
        defer { controller.shutdown() }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        let armDeadline = ContinuousClock.now + .seconds(2)
        while !controller.isActuallyHoldingSleepDisabled, ContinuousClock.now < armDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let truesBefore = helper.setCalls.filter({ $0 }).count

        // Heartbeat set throws (restore/store failure); status carries forced-off reason.
        helper.failNextSet = true
        helper.injectInterferenceOnStatus = true
        let latchDeadline = ContinuousClock.now + .seconds(3)
        while !notifier.forcedOff.contains("externalInterference"), ContinuousClock.now < latchDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(notifier.forcedOff.contains("externalInterference"))
        try await Task.sleep(for: .milliseconds(400))
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        try await Task.sleep(for: .milliseconds(300))
        #expect(helper.setCalls.filter({ $0 }).count == truesBefore + 1)
    }

    @Test("C8-2 failed heartbeat + lost status — remain nonholding, no reacquire")
    func failedHeartbeatLostEvidenceBlocksReacquire() async throws {
        let helper = FakeHelper()
        let (controller, _, _, _) = makeController(helper: helper, heartbeat: 0.12)
        defer { controller.shutdown() }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        let armDeadline = ContinuousClock.now + .seconds(2)
        while !controller.isActuallyHoldingSleepDisabled, ContinuousClock.now < armDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let truesBefore = helper.setCalls.filter({ $0 }).count

        helper.failNextSet = true
        helper.failStatus = true
        let failDeadline = ContinuousClock.now + .seconds(2)
        while helper.setCalls.filter({ $0 }).count <= truesBefore, ContinuousClock.now < failDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(500))
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        try await Task.sleep(for: .milliseconds(400))
        #expect(helper.setCalls.filter({ $0 }).count == truesBefore + 1)
        #expect(!controller.isActuallyHoldingSleepDisabled)
        if case .unavailable(.error) = controller.phase {
            // ok — awaiting evidence or transient
        } else {
            Issue.record("expected unavailable while awaiting evidence, got \(controller.phase)")
        }
    }

    @Test("C8-2 lost acquire reply releases before probing and resumes only after fresh evidence")
    func lostReplyReleasesAndFreshEvidenceResumes() async throws {
        let helper = FakeHelper()
        helper.failNextSet = true
        helper.failRelease = true
        let (controller, _, _, _) = makeController(helper: helper, heartbeat: 60)
        defer { controller.shutdown() }
        let started = AsyncStream<Void>.makeStream()
        let published = AsyncStream<Void>.makeStream()
        var reply: CheckedContinuation<PowerHelperStatus, Error>?
        helper.statusHandler = {
            try await withCheckedThrowingContinuation { continuation in
                reply = continuation
                started.continuation.yield(())
            }
        }
        controller.onChange = { published.continuation.yield(()) }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        var startIterator = started.stream.makeAsyncIterator()
        _ = await startIterator.next()
        #expect(helper.setCalls == [true, false], "release must be attempted even if its reply fails")
        #expect(!controller.wantsSleepDisabled)
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        #expect(!controller.wantsSleepDisabled, "no acquire while evidence is outstanding")
        reply?.resume(throwing: PowerHelperClientError.remote("statusLost"))
        var publishIterator = published.stream.makeAsyncIterator()
        _ = await publishIterator.next()
        #expect(!controller.wantsSleepDisabled)
        helper.statusHandler = nil
        helper.failRelease = false
        await controller.refreshFromHelper()
        let resumeDeadline = ContinuousClock.now + .seconds(2)
        while !controller.wantsSleepDisabled, ContinuousClock.now < resumeDeadline {
            await Task.yield()
        }
        #expect(controller.wantsSleepDisabled, "fresh safe status must clear the transient error")
    }

    @Test("C8-2 evidence arriving after shutdown cannot restore status or publish")
    func staleFailureEvidenceAfterShutdown() async throws {
        let helper = FakeHelper()
        helper.failNextSet = true
        let (controller, _, _, _) = makeController(helper: helper, heartbeat: 60)
        let started = AsyncStream<Void>.makeStream()
        let completed = AsyncStream<Void>.makeStream()
        var reply: CheckedContinuation<PowerHelperStatus, Error>?
        helper.statusHandler = {
            let status: PowerHelperStatus = try await withCheckedThrowingContinuation { continuation in
                reply = continuation
                started.continuation.yield(())
            }
            // Queue a MainActor barrier after the awaiting evidence task resumes.
            Task { @MainActor in completed.continuation.yield(()) }
            return status
        }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        controller.shutdown()
        let statusAtShutdown = controller.helperStatus
        var publishes = 0
        controller.onChange = { publishes += 1 }
        reply?.resume(returning: PowerHelperStatus(
            helperBuild: "late", sleepDisabled: true, setByHelper: true,
            holderCount: 1, callerIsHolder: true, lastForcedOffReason: "externalInterference"
        ))
        var completionIterator = completed.stream.makeAsyncIterator()
        _ = await completionIterator.next()
        #expect(controller.helperStatus == statusAtShutdown)
        #expect(publishes == 0)
        #expect(controller.phase == .off)
    }

    @Test("C8-4 failed refresh preserves known recovery block until fresh healthy evidence")
    func recoveryBlockSurvivesLostRefresh() async throws {
        for flag in [0, 1, 2] {
            let helper = FakeHelper()
            helper.recoveryBlocked = flag == 0
            helper.pendingRestore = flag == 1
            helper.persistRetryNeeded = flag == 2
            let (controller, _, _, notifier) = makeController(helper: helper, heartbeat: 60)
            defer { controller.shutdown() }
            await controller.refreshFromHelper()
            helper.failStatus = true
            await controller.refreshFromHelper()
            controller.update(
                agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
            )
            #expect(!controller.wantsSleepDisabled)
            #expect(controller.phase == .unavailable(.error("recoveryBlocked")))
            #expect(controller.leftover == .recoveryBlocked)
            #expect(notifier.leftoverRecovery == 1)
            helper.failStatus = false
            helper.recoveryBlocked = false
            helper.pendingRestore = false
            helper.persistRetryNeeded = false
            await controller.refreshFromHelper()
            #expect(controller.wantsSleepDisabled)
        }
    }

    @Test("C8-4 fresh recovery evidence releases our existing holder", .timeLimit(.minutes(1)))
    func recoveryEvidenceReleasesExistingHolder() async throws {
        let helper = FakeHelper()
        let (controller, _, _, _) = makeController(helper: helper, heartbeat: 60)
        defer { controller.shutdown() }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        let armed = ContinuousClock.now + .seconds(3)
        while !controller.isActuallyHoldingSleepDisabled, ContinuousClock.now < armed {
            await Task.yield()
        }
        #expect(controller.isActuallyHoldingSleepDisabled)
        helper.pendingRestore = true
        await controller.refreshFromHelper()
        let released = ContinuousClock.now + .seconds(3)
        while !helper.setCalls.contains(false), ContinuousClock.now < released {
            await Task.yield()
        }
        #expect(helper.setCalls.contains(false))
        #expect(!controller.wantsSleepDisabled)
        #expect(!controller.isActuallyHoldingSleepDisabled)
        #expect(controller.leftover == .recoveryBlocked)
    }

    @Test("C8-4 refresh completing after shutdown is ignored")
    func staleRefreshAfterShutdown() async throws {
        let helper = FakeHelper()
        let (controller, _, _, notifier) = makeController(helper: helper, heartbeat: 60)
        let started = AsyncStream<Void>.makeStream()
        var reply: CheckedContinuation<PowerHelperStatus, Error>?
        helper.statusHandler = {
            try await withCheckedThrowingContinuation { continuation in
                reply = continuation
                started.continuation.yield(())
            }
        }
        let refreshing = Task { await controller.refreshFromHelper() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        controller.shutdown()
        reply?.resume(returning: PowerHelperStatus(helperBuild: "late", recoveryBlocked: true))
        await refreshing.value
        #expect(controller.helperStatus == nil)
        #expect(controller.leftover == nil)
        #expect(notifier.leftoverRecovery == 0)
        #expect(controller.phase == .off)
    }

    @Test("R2 NEW-1 clamp-changing settings persist and reevaluate immediately", .timeLimit(.minutes(1)))
    func clampedAssignmentPersistsAndReevaluates() async {
        let defaults = UserDefaults(suiteName: "lid-clamp-r3-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let session = LidClosedSessionStore(suiteName: UUID().uuidString, writeSink: .init(
            set: { _, _ in }, remove: { _ in }, data: { _ in nil }))
        await session.awaitLoadedForTesting()
        let (controller, _, _, _) = makeController(settings: store, sessionStore: session, heartbeat: 60)
        defer { controller.shutdown() }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        #expect(controller.phase == .off)
        controller.settings = LidSleepSettings(enabled: true, maxLidClosedSeconds: 4 * 3600, limitDurationOnAC: false)
        #expect(controller.wantsSleepDisabled)
        let restored = SettingsStore(defaults: defaults).keepAwakeLidGuard
        #expect(restored.enabled)
        #expect(restored.maxLidClosedSeconds == 3 * 3600)
        #expect(restored.limitDurationOnAC)
        // Also exercise a direct SettingsStore assignment, independently of the controller clamp.
        store.keepAwakeLidGuard = LidSleepSettings(enabled: false, maxLidClosedSeconds: 4 * 3600, limitDurationOnAC: false)
        #expect(!SettingsStore(defaults: defaults).keepAwakeLidGuard.enabled)
    }

    @Test("C8-3 saved 4h + AC exemption clamped; releases at 3h on AC")
    func maxThreeHoursIncludingAC() async throws {
        var time = 1_000.0
        let store = makeSettings()
        // Bypass store clamp by writing raw JSON then loading through approved path.
        store.keepAwakeLidGuard = LidSleepSettings(
            enabled: true,
            maxLidClosedSeconds: 4 * 3600,
            limitDurationOnAC: false
        )
        #expect(store.keepAwakeLidGuard.maxLidClosedSeconds == 3 * 3600)
        #expect(store.keepAwakeLidGuard.limitDurationOnAC)

        let lid = FakeLid()
        lid.reading = .closed
        let helper = FakeHelper()
        let (controller, _, _, _) = makeController(
            helper: helper, lid: lid, settings: store, now: { time }, heartbeat: 60
        )
        defer { controller.shutdown() }

        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        let armDeadline = ContinuousClock.now + .seconds(2)
        while helper.setCalls.filter({ $0 }).isEmpty, ContinuousClock.now < armDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.wantsSleepDisabled)

        // Just under 3h — still holding.
        time += 3 * 3600 - 1
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        #expect(controller.wantsSleepDisabled)

        // At 3h on AC — must release (Fi A3; no AC bypass).
        time += 2
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        #expect(!controller.wantsSleepDisabled)
        #expect(controller.state.maxDurationLatched)
        if case .blocked(.maxDuration) = controller.phase {
            // ok
        } else {
            Issue.record("expected blocked(maxDuration), got \(controller.phase)")
        }
    }

    @Test("C8-4 recoveryBlocked leftover is not foreign; no set(true)")
    func recoveryBlockedLeftover() async throws {
        let helper = FakeHelper()
        helper.sleepDisabled = true
        helper.setByHelper = false
        helper.holderCount = 0
        helper.callerIsHolder = false
        helper.recoveryBlocked = true
        let notifier = FakeNotifier()
        let (controller, _, _, _) = makeController(
            helper: helper, notifier: notifier, probe: { true }
        )
        defer { controller.shutdown() }
        await controller.detectLeftover()
        #expect(controller.leftover == .recoveryBlocked)
        #expect(notifier.leftoverRecovery == 1)
        #expect(notifier.leftoverForeign == 0)
        #expect(helper.setCalls.filter({ $0 }).isEmpty)

        helper.recoveryBlocked = false
        helper.pendingRestore = true
        helper.setCalls = []
        notifier.leftoverRecovery = 0
        await controller.detectLeftover()
        #expect(controller.leftover == .recoveryBlocked)
        #expect(helper.setCalls.filter({ $0 }).isEmpty)

        helper.pendingRestore = false
        helper.persistRetryNeeded = true
        await controller.detectLeftover()
        #expect(controller.leftover == .recoveryBlocked)
        #expect(helper.setCalls.filter({ $0 }).isEmpty)
    }

    @Test("C8-4 recovery flags gate ordinary arm after handshake/wake — zero set(true)")
    func recoveryFlagsGateOrdinaryAcquire() async throws {
        for flag in ["recoveryBlocked", "pendingRestore", "persistRetryNeeded"] {
            let helper = FakeHelper()
            helper.availability = .connecting
            helper.promoteOnStatus = true
            switch flag {
            case "recoveryBlocked": helper.recoveryBlocked = true
            case "pendingRestore": helper.pendingRestore = true
            default: helper.persistRetryNeeded = true
            }
            let notifier = FakeNotifier()
            let (controller, _, _, _) = makeController(
                helper: helper, notifier: notifier, heartbeat: 60
            )
            defer { controller.shutdown() }

            controller.update(
                agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
            )
            let hsDeadline = ContinuousClock.now + .seconds(2)
            while helper.statusCalls == 0, ContinuousClock.now < hsDeadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            try await Task.sleep(for: .milliseconds(150))
            #expect(helper.setCalls.filter({ $0 }).isEmpty, "set(true) despite \(flag) after handshake")
            #expect(controller.leftover == .recoveryBlocked)
            #expect(notifier.leftoverRecovery >= 1)

            // Simulated wake reevaluate must still refuse acquire.
            controller.update(
                agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
            )
            try await Task.sleep(for: .milliseconds(150))
            #expect(helper.setCalls.filter({ $0 }).isEmpty, "set(true) despite \(flag) after wake")
            if case let .unavailable(.error(msg)) = controller.phase {
                #expect(msg == "recoveryBlocked")
            } else {
                Issue.record("expected unavailable(recoveryBlocked) for \(flag), got \(controller.phase)")
            }
        }
    }

    @Test("C8-5 continuous busy source change + rearm still one armed notice")
    func armedOncePerBusyPeriodDespiteSourceChange() async throws {
        var time = 2_000.0
        let helper = FakeHelper()
        let notifier = FakeNotifier()
        let (controller, _, _, _) = makeController(
            helper: helper, notifier: notifier, now: { time }, heartbeat: 60
        )
        defer { controller.shutdown() }

        controller.update(
            agentModeActive: true, busy: busyState("a"), power: acPower(), existingFloor: .percent20
        )
        let armDeadline = ContinuousClock.now + .seconds(2)
        while notifier.armed.isEmpty, ContinuousClock.now < armDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(notifier.armed.count == 1)

        // Change contributing IDs while aggregate busy stays true.
        controller.update(
            agentModeActive: true, busy: busyState("b"), power: acPower(), existingFloor: .percent20
        )
        try await Task.sleep(for: .milliseconds(100))

        // Thermal disarm then rearm after 31 minutes — same busy period.
        time += 31 * 60
        controller.update(
            agentModeActive: true,
            busy: busyState("b"),
            power: PowerSnapshot(
                hasInternalBattery: true, onBattery: false, percent: 80, thermal: .serious
            ),
            existingFloor: .percent20
        )
        try await Task.sleep(for: .milliseconds(100))
        controller.update(
            agentModeActive: true, busy: busyState("c"), power: acPower(), existingFloor: .percent20
        )
        let rearmDeadline = ContinuousClock.now + .seconds(2)
        while !controller.wantsSleepDisabled, ContinuousClock.now < rearmDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(notifier.armed.count == 1)
    }

    @Test("C8-6 confirmed no-lid capability exposed; saved enabled cannot arm")
    func noLidCapabilityAndForbidArm() async throws {
        let helper = FakeHelper()
        let lid = FakeLid()
        lid.reading = .noLid
        let store = makeSettings()
        store.keepAwakeLidGuard = LidSleepSettings(enabled: false)
        let controller = LidSleepGuardController(
            settings: store,
            helper: helper,
            lid: lid,
            notifier: FakeNotifier(),
            now: { 1_000 },
            e2eNamedInstance: false,
            sessionStore: LidClosedSessionStore(suiteName: "nolid-\(UUID().uuidString)"),
            sleepDisabledProbe: { nil },
            heartbeatInterval: 60
        )
        defer { controller.shutdown() }
        #expect(controller.isConfirmedNoLid)
        #expect(controller.lidReading == .noLid)

        store.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        controller.settings = store.keepAwakeLidGuard
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        try await Task.sleep(for: .milliseconds(200))
        #expect(helper.setCalls.filter({ $0 }).isEmpty)
        if case .blocked(.noLid) = controller.phase {
            // ok
        } else {
            Issue.record("expected blocked(noLid), got \(controller.phase)")
        }
    }

    @Test("E2E named instance never calls helper (V-C08-6)")
    func e2eNeverTouchesHelper() async throws {
        let helper = FakeHelper()
        let (controller, _, _, _) = makeController(helper: helper, e2e: true)
        defer { controller.shutdown() }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        await controller.detectLeftover()
        await controller.refreshFromHelper()
        try await Task.sleep(for: .milliseconds(100))
        #expect(helper.setCalls.isEmpty)
        #expect(helper.statusCalls == 0)
        #expect(helper.syncCalls.isEmpty)
        #expect(controller.phase == .off)
    }

    @Test("isActuallyHolding requires wants + callerIsHolder + sleepDisabled (V-C08)")
    func actuallyHoldingTripleGate() async throws {
        let helper = FakeHelper()
        let (controller, _, _, _) = makeController(helper: helper)
        defer { controller.shutdown() }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        let deadline = ContinuousClock.now + .seconds(2)
        while !controller.wantsSleepDisabled, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        // After successful set, helper marks holder + sleepDisabled.
        let holdDeadline = ContinuousClock.now + .seconds(2)
        while !controller.isActuallyHoldingSleepDisabled, ContinuousClock.now < holdDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.isActuallyHoldingSleepDisabled)

        helper.callerIsHolder = false
        helper.sleepDisabled = true
        await controller.refreshFromHelper()
        #expect(!controller.isActuallyHoldingSleepDisabled)
    }

    @Test("invalid session restore latches max duration (C06 contract)")
    func invalidSessionLatches() {
        let suite = "lid-invalid-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Data("not-json".utf8), forKey: "lidClosedSession.v2")
        let store = LidClosedSessionStore(suiteName: suite)
        let (controller, _, _, _) = makeController(sessionStore: store)
        defer { controller.shutdown() }
        #expect(controller.state.maxDurationLatched)
    }

    @Test("V1-4 recovery queued before shutdown never notifies success", .timeLimit(.minutes(1)))
    func recoveryQueuedBeforeShutdownIgnored() async throws {
        let helper = FakeHelper()
        helper.sleepDisabled = true
        helper.setByHelper = true
        helper.holderCount = 0
        helper.callerIsHolder = false
        helper.setDelay = .milliseconds(250)
        let notifier = FakeNotifier()
        let (controller, _, _, _) = makeController(
            helper: helper, notifier: notifier, probe: { true }
        )
        let detect = Task { await controller.detectLeftover() }
        try await Task.sleep(for: .milliseconds(40))
        controller.shutdown()
        await detect.value
        #expect(notifier.leftoverRestored == 0)
        #expect(!helper.setCalls.contains(true), "must not acquire after/during shutdown recovery")
    }

    @Test("V1-4 delayed failing release does not publish restored", .timeLimit(.minutes(1)))
    func recoveryFailedReleaseNoNotify() async throws {
        let helper = FakeHelper()
        helper.sleepDisabled = true
        helper.setByHelper = true
        helper.holderCount = 0
        helper.callerIsHolder = false
        helper.failRelease = true
        let notifier = FakeNotifier()
        let (controller, _, _, _) = makeController(
            helper: helper, notifier: notifier, probe: { true }
        )
        defer { controller.shutdown() }
        await controller.detectLeftover()
        #expect(notifier.leftoverRestored == 0)
        #expect(controller.leftover == .ownResidual || helper.setCalls == [false])
    }

    @Test("V1-3 leftover probe is injectable and awaited (no sync MainActor pmset)", .timeLimit(.minutes(1)))
    func leftoverProbeOffMainActorSeam() async throws {
        final class ProbeBox: @unchecked Sendable {
            var calls = 0
        }
        let box = ProbeBox()
        let helper = FakeHelper()
        helper.sleepDisabled = false
        let (controller, _, _, _) = makeController(
            helper: helper,
            probe: {
                box.calls += 1
                // Simulate a short off-actor wait; controller awaits this.
                try? await Task.sleep(for: .milliseconds(5))
                return false
            }
        )
        defer { controller.shutdown() }
        await controller.detectLeftover()
        #expect(box.calls == 1)
        #expect(controller.leftover == nil)
    }

    @Test(
        "V1-4 stale status failure after generation bump does not publish unknownOwner",
        .timeLimit(.minutes(1))
    )
    func staleStatusFailureGenerationGated() async throws {
        let helper = FakeHelper()
        helper.sleepDisabled = true
        helper.setByHelper = false
        helper.holderCount = 0
        helper.callerIsHolder = false

        actor Gate {
            private var conts: [CheckedContinuation<Void, Never>] = []
            private var open = false
            private(set) var hasWaiter = false
            func wait() async {
                if open { return }
                hasWaiter = true
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    if open { c.resume() }
                    else { conts.append(c) }
                }
            }
            func release() {
                open = true
                let pending = conts
                conts.removeAll()
                for c in pending { c.resume() }
            }
        }
        let gate = Gate()
        helper.statusHandler = {
            await gate.wait()
            throw PowerHelperClientError.remote("staleStatus")
        }

        let (controller, _, _, _) = makeController(helper: helper, probe: { true })
        defer { controller.shutdown() }

        let detect = Task { await controller.detectLeftover() }
        let waitDeadline = ContinuousClock.now + .seconds(2)
        while await !gate.hasWaiter, ContinuousClock.now < waitDeadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        // Bump setGeneration via acquire path while the stale status is still in flight.
        let busy = KeepAwakeBusyState(
            isBusy: true,
            contributing: [
                KeepAwakeSourceReport(
                    id: "lease:g", kind: .lease, displayName: "g",
                    detail: nil, isWorkingNow: true, lastWorkingAt: Date(), health: .ok
                ),
            ],
            releaseAt: nil
        )
        controller.update(
            agentModeActive: true,
            busy: busy,
            power: PowerSnapshot(
                hasInternalBattery: true, onBattery: false, percent: 80, thermal: .nominal
            ),
            existingFloor: .percent30
        )
        // Allow requestSet to bump generation.
        try await Task.sleep(for: .milliseconds(40))
        await gate.release()
        await detect.value
        #expect(controller.leftover != .unknownOwner)
    }

    @Test(
        "NEW-2 manual restore success clears leftover; failure retains warning",
        .timeLimit(.minutes(1))
    )
    func manualRestorePresentation() async throws {
        let helper = FakeHelper()
        helper.sleepDisabled = true
        helper.setByHelper = true
        helper.holderCount = 0
        helper.callerIsHolder = false
        helper.failRelease = true
        let notifier = FakeNotifier()
        let (controller, _, _, _) = makeController(
            helper: helper, notifier: notifier, probe: { true }
        )
        defer { controller.shutdown() }

        await controller.detectLeftover()
        #expect(controller.leftover == .ownResidual)

        // Failed manual retry retains residual warning.
        controller.restoreLeftover()
        let failDeadline = ContinuousClock.now + .seconds(2)
        while helper.setCalls.isEmpty, ContinuousClock.now < failDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(40))
        #expect(controller.leftover == .ownResidual)
        #expect(notifier.leftoverRestored == 0)

        // Successful manual retry clears presentation.
        helper.failRelease = false
        helper.setCalls.removeAll()
        controller.restoreLeftover()
        let okDeadline = ContinuousClock.now + .seconds(2)
        while controller.leftover != nil, ContinuousClock.now < okDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(controller.leftover == nil)
        #expect(notifier.leftoverRestored == 1)
    }

    @Test(
        "V1-4 queued restoreLeftover then shutdown never clears or notifies",
        .timeLimit(.minutes(1))
    )
    func restoreQueuedThenShutdown() async throws {
        let helper = FakeHelper()
        helper.sleepDisabled = true
        helper.setByHelper = true
        helper.holderCount = 0
        helper.callerIsHolder = false
        helper.failRelease = true
        let notifier = FakeNotifier()
        let (controller, _, _, _) = makeController(
            helper: helper, notifier: notifier, probe: { true }
        )
        await controller.detectLeftover()
        #expect(controller.leftover == .ownResidual)
        helper.failRelease = false
        helper.setDelay = .milliseconds(250)
        controller.restoreLeftover()
        try await Task.sleep(for: .milliseconds(30))
        controller.shutdown()
        try await Task.sleep(for: .milliseconds(300))
        #expect(notifier.leftoverRestored == 0)
    }

    // MARK: - PERF1-R3 / PERF1-R7

    @Test("PERF1-FIX2 blocked probe cannot reuse superseded shared evidence", .timeLimit(.minutes(1)),
          arguments: ["recoveryBlocked", "pendingRestore", "persistRetryNeeded", "otherHolder", "failedRead"])
    func perf1Fix2ProbePreservesNewerSettingsEvidence(newEvidence: String) async throws {
        let gate = PERF1EvidenceSleepGate()
        let retry = PERF1EvidenceSleepGate()
        defer { gate.cancelAll(); retry.cancelAll() }
        let proxy = FakePowerHelperProxy()
        proxy.sleepDisabled = true
        proxy.setByHelper = true
        let client = PowerHelperClient(appBuild: "136", makeProxy: { proxy },
            statusReader: LockCountedStatusReader { .enabled }, registerService: {}, unregisterService: {}, openSettings: {})
        let controller = LidSleepGuardController(settings: makeSettings(), helper: client, lid: FakeLid(),
            notifier: FakeNotifier(), sessionStore: LidClosedSessionStore(suiteName: UUID().uuidString),
            sleepDisabledProbe: { await gate.sleep(0); return true }, heartbeatInterval: 3_600,
            evidenceSleep: { await retry.sleep($0) })
        defer { controller.shutdown() }
        let detect = PERF1Task { await controller.detectLeftover() }
        defer { detect.cancel() }
        #expect(await perf1Wait { gate.waiterCount == 1 })
        proxy.recoveryBlocked = newEvidence == "recoveryBlocked"
        proxy.pendingRestore = newEvidence == "pendingRestore"
        proxy.persistRetryNeeded = newEvidence == "persistRetryNeeded"
        if newEvidence == "otherHolder" { proxy.holderCount = 1 }
        if newEvidence == "failedRead" { proxy.statusHandler = { $0(Data()) } }
        await controller.refreshHelperAvailabilityAsync(reason: .settingsOpened)
        let latest = controller.helperStatus
        let leftover = controller.leftover
        let sets = proxy.setCalls
        gate.releaseOne()
        #expect(await detect.wait())
        #expect(controller.helperStatus == latest)
        #expect(controller.leftover == leftover)
        #expect(proxy.setCalls == sets)
    }

    @Test("PERF1-FIX2 failed user operations retain approval/recovery retries", .timeLimit(.minutes(1)),
          arguments: [false, true], [false, true])
    func perf1Fix2FailedUserOperationRetainsRetry(removal: Bool, approval: Bool) async throws {
        var clock = 0.0
        let service = Mutex(approval ? PowerHelperServiceStatusValue.requiresApproval : .enabled)
        let read: @Sendable () -> PowerHelperServiceStatusValue = { service.withLock { $0 } }
        let reader = LockCountedStatusReader(read: read)
        let proxy = FakePowerHelperProxy()
        proxy.recoveryBlocked = !approval
        let client = PowerHelperClient(appBuild: "136", now: { clock }, makeProxy: { proxy }, statusReader: reader,
            registerService: { throw PowerHelperClientError.remote("denied") },
            unregisterService: { throw PowerHelperClientError.remote("denied") }, openSettings: {})
        let retry = PERF1EvidenceSleepGate()
        defer { retry.cancelAll() }
        let controller = LidSleepGuardController(settings: makeSettings(), helper: client, lid: FakeLid(),
            notifier: FakeNotifier(), sessionStore: LidClosedSessionStore(suiteName: UUID().uuidString),
            sleepDisabledProbe: { nil }, heartbeatInterval: 3_600, evidenceSleep: { await retry.sleep($0) })
        defer { controller.shutdown() }
        await controller.refreshHelperAvailabilityAsync(reason: .launch)
        #expect(await perf1Wait { retry.waiterCount == 1 })
        var failed = false
        do {
            if removal { try await controller.unregisterHelper() }
            else { try await controller.registerHelper() }
        } catch { failed = true }
        #expect(failed)
        #expect(await perf1Wait { retry.waiterCount == 1 })
        let statuses = proxy.statusCalls
        let physical = reader.callCount
        clock = 10
        retry.releaseOne()
        #expect(await perf1Wait { reader.callCount == physical + 1 && retry.waiterCount == 1 })
        #expect(proxy.statusCalls == statuses + (approval ? 0 : 1))
        #expect(proxy.setCalls.isEmpty)
        proxy.recoveryBlocked = false
        service.withLock { $0 = .enabled }
        clock = 30
        retry.releaseOne()
        #expect(await perf1Wait { controller.helperStatus?.recoveryBlocked == false && retry.waiterCount == 0 })
        #expect(proxy.setCalls.isEmpty)
    }

    @Test("PERF1-FIX2 launch/detect/settings share one physical read and handshake", .timeLimit(.minutes(1)),
          arguments: [false, true])
    func perf1Fix2ConcurrentLaunchDetectSettings(joinDuringHandshake: Bool) async throws {
        let worker = WorkerGate()
        defer { worker.release() }
        let reader = LockCountedStatusReader(delayImpl: { _ in worker.enterAndWait() }, read: { .enabled })
        reader.delay = 1
        let proxy = FakePowerHelperProxy()
        proxy.sleepDisabled = true
        var replies: [(Data) -> Void] = []
        proxy.statusHandler = { replies.append($0) }
        let client = PowerHelperClient(appBuild: "136", callTimeout: 0.5, refreshTimeout: 2,
            now: { 0 }, makeProxy: { proxy }, statusReader: reader,
            registerService: {}, unregisterService: {}, openSettings: {})
        let settings = makeSettings()
        settings.keepAwakeLidGuard = .init(enabled: true)
        let retry = PERF1EvidenceSleepGate()
        defer { retry.cancelAll() }
        let controller = LidSleepGuardController(settings: settings, helper: client, lid: FakeLid(),
            notifier: FakeNotifier(), sessionStore: LidClosedSessionStore(suiteName: UUID().uuidString),
            sleepDisabledProbe: { true }, heartbeatInterval: 3_600, evidenceSleep: { await retry.sleep($0) })
        defer {
            proxy.statusHandler = nil
            let bytes = (try? JSONEncoder().encode(proxy.makeStatus())) ?? Data()
            replies.forEach { $0(bytes) }
            controller.shutdown()
        }
        controller.update(agentModeActive: false, busy: .init(isBusy: false, contributing: [], releaseAt: nil),
                          power: acPower(), existingFloor: .percent20)
        let launch = PERF1Task { await controller.refreshHelperAvailabilityAsync(reason: .launch) }
        defer { launch.cancel() }
        #expect(await worker.waitUntilEntered(timeoutSeconds: 2))
        if joinDuringHandshake {
            worker.release()
            #expect(await perf1Wait { !replies.isEmpty })
        }
        let detect = PERF1Task { await controller.detectLeftover() }
        let settingsOpen = PERF1Task { await controller.refreshHelperAvailabilityAsync(reason: .settingsOpened) }
        defer { detect.cancel(); settingsOpen.cancel() }
        #expect(await PERF1Completion.mainActorLatency() != nil)
        worker.release()
        #expect(await perf1Wait { !replies.isEmpty })
        let first = replies.removeFirst()
        first(try JSONEncoder().encode(proxy.makeStatus()))
        #expect(await launch.wait())
        #expect(await detect.wait())
        #expect(await settingsOpen.wait())
        #expect(reader.callCount == 1)
        #expect(proxy.statusCalls == 1)
        #expect(proxy.setCalls.isEmpty)
        #expect(controller.leftover == .foreign)
    }

    @Test("PERF1-FIX2 real-client registration/removal waits for blocked release", .timeLimit(.minutes(1)),
          arguments: [false, true], [false, true])
    func perf1Fix2UserOperationsDuringBlockedRelease(removal: Bool, toggle: Bool) async throws {
        let service = Mutex(PowerHelperServiceStatusValue.enabled)
        let registrations = Mutex(0)
        let removals = Mutex(0)
        let read: @Sendable () -> PowerHelperServiceStatusValue = { service.withLock { $0 } }
        let reader = LockCountedStatusReader(read: read)
        let proxy = FakePowerHelperProxy()
        var replies: [(Data?, String?) -> Void] = []
        let client = PowerHelperClient(appBuild: "136", callTimeout: 2, refreshTimeout: 1,
            now: { 0 }, makeProxy: { proxy }, statusReader: reader,
            registerService: { registrations.withLock { $0 += 1 } },
            unregisterService: { removals.withLock { $0 += 1 }; service.withLock { $0 = .notRegistered } },
            openSettings: {})
        let settings = makeSettings()
        settings.keepAwakeLidGuard = .init(enabled: true)
        let controller = LidSleepGuardController(settings: settings, helper: client, lid: FakeLid(),
            notifier: FakeNotifier(), sessionStore: LidClosedSessionStore(suiteName: UUID().uuidString),
            sleepDisabledProbe: { nil }, heartbeatInterval: 3_600)
        defer {
            proxy.setHandler = nil
            let bytes = try? JSONEncoder().encode(proxy.makeStatus())
            replies.forEach { $0(bytes, nil) }
            controller.shutdown()
            client.invalidateConnection(intentional: true)
        }
        controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        proxy.setHandler = { on, reply in
            if !on { replies.append(reply) }
            else { reply(try? JSONEncoder().encode(proxy.makeStatus()), nil) }
        }
        if toggle { controller.settings.enabled = false }
        else {
            controller.update(agentModeActive: true, busy: .init(isBusy: false, contributing: [], releaseAt: nil),
                              power: acPower(), existingFloor: .percent20)
        }
        #expect(await perf1Wait { replies.count == 1 })
        let statuses = proxy.statusCalls
        let entered = PERF1Completion()
        var operationError: String?
        let operation = PERF1Task {
            entered.finish()
            do {
                if removal { try await controller.unregisterHelper() }
                else { try await controller.registerHelper() }
            } catch { operationError = String(describing: error) }
        }
        defer { operation.cancel() }
        #expect(await entered.wait())
        controller.settings.enabled = true
        controller.settings.enabled = false
        #expect(await PERF1Completion.mainActorLatency() != nil)
        #expect(registrations.withLock { $0 } == 0)
        #expect(removals.withLock { $0 } == 0)
        #expect(proxy.statusCalls == statuses)
        #expect(proxy.setCalls.filter { !$0 }.count == 1)
        #expect(proxy.setCalls.filter { $0 }.count == 1)
        proxy.sleepDisabled = false
        proxy.setByHelper = false
        proxy.callerIsHolder = false
        proxy.holderCount = 0
        let release = replies.removeFirst()
        release(try JSONEncoder().encode(proxy.makeStatus()), nil)
        #expect(await operation.wait())
        #expect(operationError == nil)
        #expect(registrations.withLock { $0 } == (removal ? 0 : 1))
        #expect(removals.withLock { $0 } == (removal ? 1 : 0))
        #expect(proxy.setCalls.filter { !$0 }.count == 1)
        #expect(proxy.statusCalls == statuses + (removal ? 2 : 1))
        #expect(!controller.isActuallyHoldingSleepDisabled)
        #expect(!proxy.callerIsHolder)
    }

    private func perf1Wait(_ condition: () -> Bool, seconds: Double = 2) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition(), !Task.isCancelled, ContinuousClock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(2)) } catch { return false }
        }
        return condition()
    }

    @Test("PERF1-R3 delayed evidence cannot change release/removal/shutdown",
          .timeLimit(.minutes(1)), arguments: ["release", "removal", "shutdown"], [false, true])
    func perf1R3StaleEvidenceAcrossMutation(action: String, fails: Bool) async throws {
        let helper = FakeHelper()
        let gate = PERF1EvidenceSleepGate()
        let retry = PERF1EvidenceSleepGate()
        let (controller, _, _, notifier) = makeController(helper: helper, heartbeat: 3_600,
            evidenceSleep: { await retry.sleep($0) })
        defer { gate.cancelAll(); retry.cancelAll(); controller.shutdown() }
        controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        var stale = helper.makeStatus()
        stale.recoveryBlocked = true
        stale.lastForcedOffReason = "stale"
        helper.statusHandler = {
            await gate.sleep(0)
            if fails { throw PowerHelperClientError.remote("staleFailure") }
            return stale
        }
        let done = PERF1Completion()
        let read = Task { await controller.refreshFromHelper(); done.finish() }
        defer { read.cancel() }
        #expect(await perf1Wait { gate.waiterCount == 1 })
        switch action {
        case "release":
            controller.update(agentModeActive: true, busy: .init(isBusy: false, contributing: [], releaseAt: nil),
                              power: acPower(), existingFloor: .percent20)
            #expect(await perf1Wait { helper.setCalls.contains(false) })
        case "removal": try await controller.unregisterHelper()
        default: controller.shutdown()
        }
        let status = controller.helperStatus
        let phase = controller.phase
        let notices = notifier.forcedOff.count
        let retries = retry.delayCount
        gate.cancelAll()
        #expect(await done.wait())
        #expect(controller.helperStatus == status)
        #expect(controller.phase == phase)
        #expect(notifier.forcedOff.count == notices)
        #expect(retry.delayCount == retries)
        #expect(!controller.isActuallyHoldingSleepDisabled)
    }

    @Test("PERF1-NEW-5 blocked restoration preserves expired origin and latch", .timeLimit(.minutes(1)),
          arguments: [false, true])
    func perf1New5LoadingPreservesSession(latched: Bool) async throws {
        let gate = WorkerGate()
        defer { gate.release() }
        let boot = try #require(LidMonotonicTime.bootSessionUUID())
        let snapshot = LidClosedSessionStore.Snapshot(continuousClosedAt: 1, bootSessionUUID: boot,
            maxDurationLatched: latched, wallClosedAt: Date(timeIntervalSince1970: 1))
        let bytes = try JSONEncoder().encode(snapshot)
        let writes = Mutex(0)
        let session = LidClosedSessionStore(suiteName: UUID().uuidString, writeSink: .init(
            set: { _, _ in writes.withLock { $0 += 1 } }, remove: { _ in },
            data: { _ in gate.enterAndWait(); return bytes }))
        let lid = FakeLid()
        lid.reading = .closed
        let (controller, helper, _, _) = makeController(lid: lid, now: { 20_000 }, sessionStore: session)
        defer { controller.shutdown() }
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        for _ in 0..<20 {
            controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        }
        #expect(helper.setCalls.filter { $0 }.isEmpty)
        #expect(writes.withLock { $0 } == 0)
        gate.release()
        #expect(await perf1Wait { controller.state.lidClosedSince == 1 })
        #expect(controller.state.maxDurationLatched)
        #expect(helper.setCalls.filter { $0 }.isEmpty)
        #expect(session.load()?.continuousClosedAt == 1)
    }

    @Test("PERF1-R3 fresh evidence waits for release/removal completion", .timeLimit(.minutes(1)),
          arguments: [false, true])
    func perf1R3EvidenceWaitsForMutation(removal: Bool) async throws {
        let gate = PERF1EvidenceSleepGate()
        defer { gate.cancelAll() }
        let (controller, helper, _, _) = makeController(heartbeat: 3_600)
        defer { controller.shutdown() }
        controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        helper.beforeSet = { on in if !on && !removal { await gate.sleep(0) } }
        helper.unregisterHandler = { await gate.sleep(0) }
        let operation = PERF1Task {
            if removal { try? await controller.unregisterHelper() }
            else {
                controller.update(agentModeActive: true, busy: .init(isBusy: false, contributing: [], releaseAt: nil),
                                  power: acPower(), existingFloor: .percent20)
            }
        }
        defer { operation.cancel() }
        #expect(await perf1Wait { gate.waiterCount == 1 })
        let statuses = helper.statusCalls
        await controller.refreshFromHelper()
        await controller.refreshHelperAvailabilityAsync(reason: .settingsOpened)
        #expect(helper.statusCalls == statuses, "no fresh status while mutation is blocked")
        gate.releaseOne()
        #expect(await operation.wait())
        #expect(await perf1Wait { removal ? helper.availability == .notRegistered : !helper.callerIsHolder })
        if !removal { #expect(await perf1Wait { helper.statusCalls == statuses + 1 }) }
        #expect(!controller.isActuallyHoldingSleepDisabled)
    }

    @Test("PERF1-NEW-8 failed holding evidence releases then recovers heartbeats", .timeLimit(.minutes(1)))
    func perf1New8StatusFailureRecoversHeartbeats() async throws {
        let retry = PERF1EvidenceSleepGate()
        let (controller, helper, _, _) = makeController(heartbeat: 0.05, evidenceSleep: { await retry.sleep($0) })
        defer { retry.cancelAll(); controller.shutdown() }
        controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        helper.failStatus = true
        await controller.refreshFromHelper()
        #expect(!controller.wantsSleepDisabled)
        #expect(!controller.isActuallyHoldingSleepDisabled)
        #expect(await perf1Wait { helper.setCalls.contains(false) })
        helper.failStatus = false
        await controller.refreshFromHelper()
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        let acquired = helper.setCalls.filter { $0 }.count
        #expect(await perf1Wait { helper.setCalls.filter { $0 }.count >= acquired + 2 })
        #expect(controller.isActuallyHoldingSleepDisabled)
    }

    @Test("PERF1-R5 first closed start waits for backend durability", .timeLimit(.minutes(1)))
    func perf1R5AcquireWaitsForStartDurability() async {
        let gate = WorkerGate()
        defer { gate.release() }
        let session = LidClosedSessionStore(suiteName: UUID().uuidString, writeSink: .init(
            set: { _, _ in gate.enterAndWait() }, remove: { _ in }, data: { _ in nil }))
        await session.awaitLoadedForTesting()
        let lid = FakeLid()
        lid.reading = .closed
        let (controller, helper, _, _) = makeController(lid: lid, sessionStore: session, heartbeat: 3_600)
        defer { controller.shutdown() }
        controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        for _ in 0..<20 {
            controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        }
        #expect(helper.setCalls.isEmpty)
        #expect(!controller.wantsSleepDisabled)
        gate.release()
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        #expect(session.backendWriteCountForTesting == 1)
    }

    @Test("PERF1-R5/NEW-8 armed then closed resumes heartbeats after durability", .timeLimit(.minutes(1)))
    func perf1ClosedHoldingResumesHeartbeatsAfterDurability() async {
        let gate = WorkerGate()
        defer { gate.release() }
        let session = LidClosedSessionStore(suiteName: UUID().uuidString, writeSink: .init(
            set: { _, _ in gate.enterAndWait() }, remove: { _ in }, data: { _ in nil }))
        await session.awaitLoadedForTesting()
        let (controller, helper, lid, _) = makeController(sessionStore: session, heartbeat: 0.05)
        defer { controller.shutdown() }
        controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        lid.publish(.closed)
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        let before = helper.setCalls.filter { $0 }.count
        gate.release()
        #expect(await perf1Wait { helper.setCalls.filter { $0 }.count >= before + 2 })
        #expect(controller.isActuallyHoldingSleepDisabled)
    }

    @Test("PERF1-R3 recovery health discovered while holding preserves retry", .timeLimit(.minutes(1)),
          arguments: ["recoveryBlocked", "pendingRestore", "persistRetryNeeded"])
    func perf1HoldingRecoveryBlockRetainsRetry(flag: String) async {
        let retry = PERF1EvidenceSleepGate()
        defer { retry.cancelAll() }
        let (controller, helper, _, _) = makeController(heartbeat: 3_600, evidenceSleep: { await retry.sleep($0) })
        defer { controller.shutdown() }
        controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        helper.recoveryBlocked = flag == "recoveryBlocked"
        helper.pendingRestore = flag == "pendingRestore"
        helper.persistRetryNeeded = flag == "persistRetryNeeded"
        await controller.refreshFromHelper()
        #expect(await perf1Wait { helper.setCalls.contains(false) && retry.waiterCount == 1 })
        #expect(!controller.isActuallyHoldingSleepDisabled)
        #expect(retry.recordedDelays == [5])
        let statuses = helper.statusCalls
        helper.recoveryBlocked = false
        helper.pendingRestore = false
        helper.persistRetryNeeded = false
        retry.releaseOne()
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        #expect(helper.statusCalls == statuses + 1)
    }

    @Test("PERF1-R3/NEW-9 deferred invalidation cannot handshake before SM approval", .timeLimit(.minutes(1)))
    func perf1DeferredSMRefreshGatesEvidenceXPC() async throws {
        var clock = 0.0
        let service = Mutex(PowerHelperServiceStatusValue.enabled)
        let readService: @Sendable () -> PowerHelperServiceStatusValue = { service.withLock { $0 } }
        let reader = LockCountedStatusReader(read: readService)
        let proxy = FakePowerHelperProxy()
        let client = PowerHelperClient(appBuild: "136", now: { clock }, makeProxy: { proxy },
            statusReader: reader, registerService: {}, unregisterService: {}, openSettings: {})
        defer { client.invalidateConnection(intentional: true) }
        let retry = PERF1EvidenceSleepGate()
        defer { retry.cancelAll() }
        let settings = makeSettings()
        settings.keepAwakeLidGuard = .init(enabled: true)
        let controller = LidSleepGuardController(settings: settings, helper: client, lid: FakeLid(),
            notifier: FakeNotifier(), sessionStore: LidClosedSessionStore(suiteName: UUID().uuidString),
            sleepDisabledProbe: { nil }, heartbeatInterval: 3_600, evidenceSleep: { await retry.sleep($0) })
        defer { controller.shutdown() }
        controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        let statuses = proxy.statusCalls
        let acquires = proxy.setCalls.filter { $0 }.count
        service.withLock { $0 = .requiresApproval }
        clock = 1
        client.invalidateConnection()
        await controller.refreshFromHelper()
        #expect(await perf1Wait { retry.waiterCount == 1 })
        #expect(reader.callCount == 1)
        #expect(proxy.statusCalls == statuses, "unsampled current epoch must issue zero handshakes")
        clock = 5
        await controller.refreshFromHelper()
        #expect(client.availability == .requiresApproval)
        #expect(reader.callCount == 2)
        #expect(proxy.statusCalls == statuses)
        #expect(proxy.setCalls.filter { $0 }.count == acquires)
        clock = 10
        service.withLock { $0 = .enabled }
        await controller.refreshFromHelper()
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        #expect(proxy.statusCalls == statuses + 1)
    }

    @Test("PERF1-R5/NEW-7 shutdown drains off actor within one shared second", .timeLimit(.minutes(1)),
          arguments: [false, true])
    func perf1New7ShutdownSharedDeadline(silent: Bool) async throws {
        let gate = WorkerGate()
        defer { gate.release() }
        let bytes = Mutex<Data?>(nil)
        let session = LidClosedSessionStore(suiteName: UUID().uuidString, writeSink: .init(
            set: { data, _ in gate.enterAndWait(); bytes.withLock { $0 = data } },
            remove: { _ in bytes.withLock { $0 = nil } }, data: { _ in nil }))
        await session.awaitLoadedForTesting()
        let proxy = FakePowerHelperProxy()
        let client = PowerHelperClient(appBuild: "136", makeProxy: { proxy },
            statusReader: LockCountedStatusReader { .enabled }, registerService: {}, unregisterService: {}, openSettings: {})
        let settings = makeSettings()
        settings.keepAwakeLidGuard = .init(enabled: true)
        let lid = FakeLid()
        let controller = LidSleepGuardController(settings: settings, helper: client, lid: lid,
            notifier: FakeNotifier(), sessionStore: session, sleepDisabledProbe: { nil }, heartbeatInterval: 3_600)
        defer { controller.shutdown() }
        controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        lid.publish(.closed)
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        if silent { proxy.setHandler = { _, _ in } }
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(30)) { gate.release() }
        let start = ContinuousClock.now
        controller.shutdown()
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1))
        #expect(bytes.withLock { $0 } != nil, "durability must complete before shutdown returns")
        #expect(!session.hasPendingDurability)
        #expect(proxy.setCalls.last == false)
        print("PERF1 shutdown silent=\(silent): \(elapsed)")
    }

    @Test("PERF1-R3 requiresApproval starts SM-only backoff; settings does not reset", .timeLimit(.minutes(1)))
    func perf1R3ApprovalBackoffSMOnly() async throws {
        let helper = FakeHelper()
        helper.availability = .requiresApproval
        let sleepGate = PERF1EvidenceSleepGate()
        defer { sleepGate.cancelAll() }
        let (controller, _, _, _) = makeController(
            helper: helper,
            heartbeat: 3_600,
            evidenceSleep: { await sleepGate.sleep($0) }
        )
        defer { controller.shutdown() }

        await controller.refreshHelperAvailabilityAsync(reason: .launch)
        #expect(helper.refreshCalls.filter { $0 == .launch }.count == 1)
        #expect(helper.statusCalls == 0)
        #expect(helper.setCalls.isEmpty)
        #expect(await perf1Wait { sleepGate.delayCount == 1 })
        #expect(sleepGate.recordedDelays.first == 5)

        // Settings open must not reset / replace the armed backoff chain.
        await controller.refreshHelperAvailabilityAsync(reason: .settingsOpened)
        #expect(await perf1Wait { sleepGate.delayCount == 1 })
        #expect(helper.statusCalls == 0)

        sleepGate.releaseOne()
        let deadline = ContinuousClock.now + .seconds(2)
        while sleepGate.delayCount < 2, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(helper.refreshCalls.contains(.retry))
        #expect(helper.statusCalls == 0)
        #expect(helper.setCalls.isEmpty)
        #expect(sleepGate.recordedDelays.prefix(2) == [5, 10])
    }

    @Test("PERF1-R3 recoveryBlocked retries read-only status; never acquire", .timeLimit(.minutes(1)))
    func perf1R3RecoveryReadOnlyBackoff() async throws {
        let helper = FakeHelper()
        helper.availability = .ready
        helper.recoveryBlocked = true
        let sleepGate = PERF1EvidenceSleepGate()
        defer { sleepGate.cancelAll() }
        let (controller, _, _, _) = makeController(
            helper: helper,
            heartbeat: 3_600,
            evidenceSleep: { await sleepGate.sleep($0) }
        )
        defer { controller.shutdown() }

        await controller.refreshHelperAvailabilityAsync(reason: .wake)
        #expect(helper.statusCalls == 1)
        #expect(helper.setCalls.filter { $0 }.isEmpty)
        #expect(controller.leftover == .recoveryBlocked)

        let statusAfterLaunch = helper.statusCalls
        sleepGate.releaseOne()
        let deadline = ContinuousClock.now + .seconds(2)
        while helper.statusCalls <= statusAfterLaunch, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(helper.statusCalls == statusAfterLaunch + 1)
        #expect(helper.setCalls.filter { $0 }.isEmpty)
        #expect(helper.refreshCalls.contains(.retry))
    }

    @Test("PERF1-R3 connection drop starts one coordinator handshake", .timeLimit(.minutes(1)))
    func perf1R3ConnectionDropHandshake() async throws {
        let helper = FakeHelper()
        helper.availability = .ready
        helper.promoteOnStatus = true
        let (controller, _, _, _) = makeController(helper: helper, heartbeat: 3_600)
        defer { controller.shutdown() }
        await controller.refreshHelperAvailabilityAsync(reason: .launch)
        let statusBefore = helper.statusCalls
        helper.refreshCalls.removeAll()

        helper.availability = .connecting
        helper.onAvailabilityChange?()
        let deadline = ContinuousClock.now + .seconds(2)
        while !helper.refreshCalls.contains(.connectionInvalidated), ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(helper.refreshCalls.filter { $0 == .connectionInvalidated }.count == 1)
        while helper.statusCalls <= statusBefore, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(helper.statusCalls == statusBefore + 1)
        #expect(helper.availability == .ready)
    }

    @Test("PERF1-R3 launch+detectLeftover coalesce to one refresh", .timeLimit(.minutes(1)))
    func perf1R3LaunchDetectCoalesce() async throws {
        let helper = FakeHelper()
        helper.availability = .connecting
        helper.promoteOnStatus = true
        let gate = PERF1EvidenceSleepGate()
        defer { gate.cancelAll() }
        var refreshes = 0
        helper.refreshHandler = { _ in
            refreshes += 1
            if refreshes == 1 { await gate.sleep(0) }
        }
        let (controller, _, _, _) = makeController(helper: helper, heartbeat: 3_600)
        defer { controller.shutdown() }
        controller.update(agentModeActive: false, busy: .init(isBusy: false, contributing: [], releaseAt: nil),
                          power: acPower(), existingFloor: .percent20)
        #expect(await perf1Wait { gate.waiterCount == 1 })
        let detect = PERF1Task { await controller.detectLeftover() }
        defer { detect.cancel() }
        await Task.yield()
        #expect(refreshes == 1)
        gate.releaseOne()
        #expect(await detect.wait())
        #expect(refreshes == 1)
        #expect(helper.statusCalls == 1)
    }

    @Test("PERF1-R7 MainActor and actual release during real 1s SM read", .timeLimit(.minutes(1)))
    func perf1R7MainActorLatencyDuringSlowStatus() async throws {
        let gate = WorkerGate()
        defer { gate.release() }
        let reader = LockCountedStatusReader(delayImpl: { gate.enterThenSleep($0) }, read: { .enabled })
        var clock = 0.0
        let proxy = FakePowerHelperProxy()
        let client = PowerHelperClient(appBuild: "136", callTimeout: 2, refreshTimeout: 5,
            now: { clock }, makeProxy: { proxy }, statusReader: reader,
            registerService: {}, unregisterService: {}, openSettings: {})
        let settings = makeSettings()
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        let session = LidClosedSessionStore(suiteName: UUID().uuidString, writeSink: .init(
            set: { _, _ in }, remove: { _ in }, data: { _ in nil }))
        await session.awaitLoadedForTesting()
        let controller = LidSleepGuardController(settings: settings, helper: client, lid: FakeLid(),
            notifier: FakeNotifier(), sessionStore: session, sleepDisabledProbe: { nil }, heartbeatInterval: 3_600)
        defer { controller.shutdown() }
        controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        #expect(await perf1Wait { controller.isActuallyHoldingSleepDisabled })
        #expect(proxy.callerIsHolder)
        #expect(reader.callCount == 1)

        // Prime a confirmed holder before blocking the next permitted physical read.
        clock = 5
        reader.delay = 1
        let completion = PERF1Completion()
        let refresh = Task { await controller.refreshHelperAvailabilityAsync(reason: .settingsOpened); completion.finish() }
        defer { refresh.cancel() }
        #expect(await gate.waitUntilEntered(timeoutSeconds: 2))
        var durations: [Duration] = []
        for _ in 0..<20 {
            let start = ContinuousClock.now
            controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
            durations.append(ContinuousClock.now - start)
        }
        #expect(gate.hasEntered && !gate.hasFinished)
        #expect(durations.allSatisfy { $0 < .milliseconds(50) })
        #expect(reader.callCount == 2)
        let start = ContinuousClock.now
        controller.update(agentModeActive: true, busy: .init(isBusy: false, contributing: [], releaseAt: nil),
                          power: acPower(), existingFloor: .percent20)
        let releaseDuration = ContinuousClock.now - start
        #expect(releaseDuration < .milliseconds(50))
        #expect(await perf1Wait({ proxy.setCalls.last == false && !proxy.callerIsHolder }, seconds: 0.3))
        #expect(!gate.hasFinished, "actual release must complete during the blocked SM getter")
        #expect(!controller.isActuallyHoldingSleepDisabled)
        let sentinel = await PERF1Completion.mainActorLatency()
        #expect(sentinel.map { $0 < .milliseconds(50) } == true)
        #expect(await completion.wait())
        #expect(await perf1Wait { gate.hasFinished })
        #expect(gate.hasFinished)
        #expect(reader.callCount == 2)
        print("PERF1 updates max=\(durations.max() ?? .zero), release=\(releaseDuration), sentinel=\(String(describing: sentinel))")
    }

    @Test("PERF1-R3 round3 register requiring approval starts SM-only retry", .timeLimit(.minutes(1)))
    func perf1R3RegisterApprovalStartsSMOnlyRetry() async throws {
        var clock: TimeInterval = 0
        let reader = LockCountedStatusReader { .requiresApproval }
        let proxy = FakePowerHelperProxy()
        let client = PowerHelperClient(
            appBuild: "136",
            refreshTimeout: 1,
            minimumPhysicalInterval: 5,
            now: { clock },
            makeProxy: { proxy },
            statusReader: reader,
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        let sleepGate = PERF1EvidenceSleepGate()
        defer { sleepGate.cancelAll() }
        let store = SettingsStore(defaults: UserDefaults(suiteName: "perf1-r3-reg-\(UUID().uuidString)")!)
        store.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        let controller = LidSleepGuardController(
            settings: store,
            helper: client,
            lid: FakeLid(),
            notifier: FakeNotifier(),
            sessionStore: LidClosedSessionStore(suiteName: "perf1-r3-reg-s-\(UUID().uuidString)"),
            sleepDisabledProbe: { nil },
            heartbeatInterval: 3_600,
            evidenceSleep: { await sleepGate.sleep($0) }
        )
        defer { controller.shutdown() }

        try await controller.registerHelper()
        #expect(client.availability == .requiresApproval)
        #expect(proxy.statusCalls == 0 && proxy.setCalls.isEmpty)
        let armed = ContinuousClock.now + .seconds(2)
        while sleepGate.delayCount < 1, ContinuousClock.now < armed {
            await Task.yield()
        }
        #expect(await perf1Wait { sleepGate.delayCount == 1 })
        let smBeforeRetry = reader.callCount
        clock = 5
        sleepGate.releaseOne()
        let deadline = ContinuousClock.now + .seconds(2)
        while reader.callCount <= smBeforeRetry, ContinuousClock.now < deadline {
            await Task.yield()
        }
        #expect(reader.callCount == smBeforeRetry + 1)
        #expect(client.availability == .requiresApproval)
        #expect(proxy.statusCalls == 0 && proxy.setCalls.isEmpty)
        #expect(!client.handshakeCompleteForTesting)
    }

    @Test("PERF1-R7 approval backoff counted SM-only through injected schedule", .timeLimit(.minutes(1)))
    func perf1R7ApprovalBackoffCallCounts() async throws {
        var clock: TimeInterval = 0
        let reader = LockCountedStatusReader { .requiresApproval }
        let proxy = FakePowerHelperProxy()
        let client = PowerHelperClient(
            appBuild: "136",
            refreshTimeout: 1,
            minimumPhysicalInterval: 5,
            now: { clock },
            makeProxy: { proxy },
            statusReader: reader,
            registerService: {},
            unregisterService: {},
            openSettings: {}
        )
        let sleepGate = PERF1EvidenceSleepGate()
        defer { sleepGate.cancelAll() }
        let store = SettingsStore(defaults: UserDefaults(suiteName: "perf1-r7-ap-\(UUID().uuidString)")!)
        store.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        let controller = LidSleepGuardController(
            settings: store,
            helper: client,
            lid: FakeLid(),
            notifier: FakeNotifier(),
            sessionStore: LidClosedSessionStore(suiteName: "perf1-r7-ap-s-\(UUID().uuidString)"),
            sleepDisabledProbe: { nil },
            heartbeatInterval: 3_600,
            evidenceSleep: { await sleepGate.sleep($0) }
        )
        defer { controller.shutdown() }

        // t=0 launch
        await controller.refreshHelperAvailabilityAsync(reason: .launch)
        #expect(reader.callCount == 1)
        #expect(client.availability == .requiresApproval)
        #expect(proxy.statusCalls == 0 && proxy.setCalls.isEmpty)
        #expect(await perf1Wait { sleepGate.delayCount == 1 })

        // Evaluator storm: zero additional SM
        for _ in 0..<20 {
            controller.update(
                agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
            )
        }
        #expect(reader.callCount == 1)

        // Advance backoff: t=5,15,35,75 → four more SM reads (5 total)
        let advances: [TimeInterval] = [5, 15, 35, 75]
        for (index, t) in advances.enumerated() {
            // Wait until the next sleep is armed before releasing it.
            let armed = ContinuousClock.now + .seconds(2)
            while sleepGate.delayCount < index + 1, ContinuousClock.now < armed {
                await Task.yield()
            }
            clock = t
            sleepGate.releaseOne()
            let deadline = ContinuousClock.now + .seconds(2)
            while reader.callCount < index + 2, ContinuousClock.now < deadline {
                await Task.yield()
            }
            #expect(reader.callCount == index + 2)
        }
        #expect(reader.callCount == 5)
        #expect(client.availability == .requiresApproval)
        #expect(proxy.statusCalls == 0 && proxy.setCalls.isEmpty)
    }

    @Test("PERF1-R7 recovery backoff counts physical SM and XPC through t=75", .timeLimit(.minutes(1)))
    func perf1R7RecoveryBackoffCallCounts() async throws {
        var clock = 0.0
        let reader = LockCountedStatusReader { .enabled }
        let proxy = FakePowerHelperProxy()
        proxy.recoveryBlocked = true
        let client = PowerHelperClient(appBuild: "136", now: { clock }, makeProxy: { proxy },
            statusReader: reader, registerService: {}, unregisterService: {}, openSettings: {})
        let sleepGate = PERF1EvidenceSleepGate()
        defer { sleepGate.cancelAll() }
        let settings = makeSettings()
        settings.keepAwakeLidGuard = .init(enabled: true)
        let controller = LidSleepGuardController(settings: settings, helper: client, lid: FakeLid(),
            notifier: FakeNotifier(), sessionStore: LidClosedSessionStore(suiteName: UUID().uuidString),
            sleepDisabledProbe: { nil }, heartbeatInterval: 3_600, evidenceSleep: { await sleepGate.sleep($0) })
        defer { controller.shutdown() }
        controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        #expect(await perf1Wait { sleepGate.delayCount == 1 })
        #expect(reader.callCount == 1)
        #expect(proxy.statusCalls == 1)
        for _ in 0..<20 {
            controller.update(agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20)
        }
        #expect(reader.callCount == 1)
        #expect(proxy.statusCalls == 1)
        for (index, time) in [5.0, 15, 35, 75].enumerated() {
            #expect(await perf1Wait { sleepGate.waiterCount == 1 })
            clock = time
            sleepGate.releaseOne()
            #expect(await perf1Wait { proxy.statusCalls == index + 2 && sleepGate.delayCount == index + 2 })
            #expect(reader.callCount == index + 2)
            #expect(proxy.statusCalls == index + 2)
            #expect(proxy.setCalls.isEmpty)
        }
        #expect(reader.callCount == 5)
        #expect(proxy.statusCalls == 5)
        #expect(sleepGate.recordedDelays == [5, 10, 20, 40, 80])
    }

    @Test("PERF1-NEW-3 wake failed status keeps evidence latch; no reacquire from cache", .timeLimit(.minutes(1)))
    func perf1New3WakeFailedStatusKeepsLatch() async throws {
        let helper = FakeHelper()
        helper.failNextSet = true
        helper.failStatus = true
        let sleepGate = PERF1EvidenceSleepGate()
        defer { sleepGate.cancelAll() }
        let (controller, _, _, _) = makeController(
            helper: helper,
            heartbeat: 3_600,
            evidenceSleep: { await sleepGate.sleep($0) }
        )
        defer { controller.shutdown() }

        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        let latchDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < latchDeadline {
            if case .unavailable(.error) = controller.phase, !controller.wantsSleepDisabled {
                break
            }
            await Task.yield()
        }
        #expect(!controller.wantsSleepDisabled)
        #expect(!controller.isActuallyHoldingSleepDisabled)

        let truesBeforeWake = helper.setCalls.filter { $0 }.count
        let statusBeforeWake = helper.statusCalls
        // Cached .ready alone must not clear latch after a failed wake status read.
        helper.failStatus = true
        await controller.refreshFromHelper()
        #expect(helper.statusCalls >= statusBeforeWake + 1)
        #expect(!controller.wantsSleepDisabled)
        #expect(!controller.isActuallyHoldingSleepDisabled)
        #expect(controller.helperStatus?.callerIsHolder != true)
        #expect(helper.setCalls.filter { $0 }.count == truesBeforeWake)
        if case .unavailable(.error) = controller.phase {
            // still latched
        } else {
            Issue.record("expected unavailable while evidence latch held, got \(controller.phase)")
        }

        // Fresh healthy status (same path as lostReply resume) clears latch.
        helper.failStatus = false
        helper.statusHandler = nil
        await controller.refreshFromHelper()
        controller.update(
            agentModeActive: true, busy: busyState("lease:resume"), power: acPower(), existingFloor: .percent20
        )
        let resumeDeadline = ContinuousClock.now + .seconds(2)
        while !controller.wantsSleepDisabled, ContinuousClock.now < resumeDeadline {
            await Task.yield()
        }
        #expect(controller.wantsSleepDisabled)
    }

    @Test("PERF1-NEW-4 recoveryBlocked to healthy-idle cancels armed retry", .timeLimit(.minutes(1)))
    func perf1New4HealthyIdleCancelsArmedRetry() async throws {
        let helper = FakeHelper()
        helper.availability = .ready
        helper.recoveryBlocked = true
        let sleepGate = PERF1EvidenceSleepGate()
        defer { sleepGate.cancelAll() }
        let (controller, _, _, _) = makeController(
            helper: helper,
            heartbeat: 3_600,
            evidenceSleep: { await sleepGate.sleep($0) }
        )
        defer { controller.shutdown() }

        await controller.refreshHelperAvailabilityAsync(reason: .wake)
        #expect(controller.leftover == .recoveryBlocked)
        let armed = ContinuousClock.now + .seconds(2)
        while sleepGate.delayCount < 1, ContinuousClock.now < armed {
            await Task.yield()
        }
        #expect(await perf1Wait { sleepGate.delayCount == 1 })
        let refreshBeforeHealthy = helper.refreshCalls.count
        let statusBeforeHealthy = helper.statusCalls

        // Recover to healthy idle (policy does not want hold) — must cancel armed retry.
        helper.recoveryBlocked = false
        await controller.refreshHelperAvailabilityAsync(reason: .wake)
        #expect(controller.leftover == nil)
        #expect(helper.statusCalls == statusBeforeHealthy + 1)

        let retryRefreshesBefore = helper.refreshCalls.filter { $0 == .retry }.count
        // Release the previously armed sleep — invalidated generation must do nothing.
        sleepGate.releaseOne()
        let settleDeadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < settleDeadline {
            await Task.yield()
        }
        #expect(helper.refreshCalls.filter { $0 == .retry }.count == retryRefreshesBefore)
        #expect(helper.refreshCalls.count == refreshBeforeHealthy + 1)
        #expect(helper.statusCalls == statusBeforeHealthy + 1)
        #expect(helper.setCalls.filter { $0 }.isEmpty)
        #expect(await perf1Wait { sleepGate.delayCount == 1 })
    }
}
