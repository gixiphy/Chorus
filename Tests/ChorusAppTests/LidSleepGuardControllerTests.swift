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
        var setCalls: [Bool] = []
        var statusCalls = 0
        var syncCalls: [(Bool, TimeInterval)] = []
        var failNextSet = false
        var hangSet = false
        var hangSync = false
        var setDelay: Duration = .seconds(0)

        func refreshAvailability() {}
        func register() async throws {}
        func unregister() async throws {}
        func openApprovalSettings() {}

        func setSleepDisabled(_ on: Bool) async throws -> PowerHelperStatus {
            setCalls.append(on)
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
            sleepDisabled = on
            setByHelper = on || setByHelper
            callerIsHolder = on
            holderCount = on ? 1 : 0
            if !on { setByHelper = false }
            return makeStatus()
        }

        func status() async throws -> PowerHelperStatus {
            statusCalls += 1
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
                lastForcedOffReason: forcedOffReason
            )
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
        store.keepAwakeLidGuard = LidSleepSettings(enabled: true)
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

    @Test("armed notification throttled once per busy period / 30min (V-C08-4)")
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
