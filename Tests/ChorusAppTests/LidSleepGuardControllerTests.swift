import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("LidSleepGuardController")
struct LidSleepGuardControllerTests {
    final class FakeHelper: PowerHelperClienting {
        var availability: LidHelperAvailability = .ready
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

        func refreshAvailability() {}
        func register() async throws {}
        func unregister() async throws {}
        func openApprovalSettings() {}

        func setSleepDisabled(_ on: Bool) async throws -> PowerHelperStatus {
            setCalls.append(on)
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
        probe: @escaping () -> Bool? = { nil },
        sessionStore: LidClosedSessionStore = LidClosedSessionStore(
            suiteName: "lid-session-\(UUID().uuidString)"
        ),
        heartbeat: TimeInterval = 0.15
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
            heartbeatInterval: heartbeat
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

        // Backoff retry (~1s) should attempt set again.
        let retryDeadline = ContinuousClock.now + .seconds(3)
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
                func refreshAvailability() {}
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
        let changes = AsyncStream<Void>.makeStream()
        controller.onChange = { changes.continuation.yield(()) }
        controller.update(
            agentModeActive: true, busy: busyState(), power: acPower(), existingFloor: .percent20
        )
        var iterator = changes.stream.makeAsyncIterator()
        while !controller.isActuallyHoldingSleepDisabled { _ = await iterator.next() }
        helper.pendingRestore = true
        await controller.refreshFromHelper()
        while !helper.setCalls.contains(false) { _ = await iterator.next() }
        #expect(!controller.wantsSleepDisabled)
        #expect(!controller.isActuallyHoldingSleepDisabled)
        #expect(helper.setCalls == [true, false])
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

    @Test("R2 NEW-1 clamp-changing settings persist and reevaluate immediately")
    func clampedAssignmentPersistsAndReevaluates() {
        let defaults = UserDefaults(suiteName: "lid-clamp-r3-\(UUID().uuidString)")!
        let store = SettingsStore(defaults: defaults)
        let (controller, _, _, _) = makeController(settings: store, heartbeat: 60)
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
}
