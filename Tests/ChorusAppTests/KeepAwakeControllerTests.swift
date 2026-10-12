import AppKit
import ChorusCore
import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Chorus

@MainActor
@Suite("KeepAwakeController")
struct KeepAwakeControllerTests {
    final class FakeAssertions: KeepAwakeAsserting {
        var active: [IOPMAssertionID: String] = [:]
        var failingTypes: Set<String> = []
        var nextID: IOPMAssertionID = 0
        var released: [IOPMAssertionID] = []

        func create(type: String, reason: String) -> IOPMAssertionID? {
            guard !failingTypes.contains(type) else { return nil }
            let id = nextID
            nextID += 1
            active[id] = type
            return id
        }

        func isActive(_ id: IOPMAssertionID) -> Bool { active[id] != nil }
        func release(_ id: IOPMAssertionID) {
            released.append(id)
            active.removeValue(forKey: id)
        }
    }

    final class FakePowerSource: PowerSourceObserving {
        var snapshot = PowerSnapshot(
            hasInternalBattery: true, onBattery: false, percent: 80, thermal: .nominal
        )
        var onChange: (() -> Void)?
        private(set) var started = false

        func start() { started = true }
        func stop() { started = false }

        func publish(_ next: PowerSnapshot) {
            snapshot = next
            onChange?()
        }
    }

    final class FakeNotifier: KeepAwakeNotifying {
        var paused: [PowerFloorState] = []
        func notifyPowerFloorPaused(_ state: PowerFloorState) { paused.append(state) }
    }

    final class FakeLidHelper: PowerHelperClienting {
        var availability: LidHelperAvailability = .ready
        var onAvailabilityChange: (() -> Void)?
        private(set) var setCalls: [Bool] = []
        private(set) var syncCalls = 0
        var recoveryBlocked = false
        var pendingRestore = false
        var persistRetryNeeded = false

        func refreshAvailability() {}
        func register() async throws {}
        func unregister() async throws {}
        func openApprovalSettings() {}
        func setSleepDisabled(_ on: Bool) async throws -> PowerHelperStatus {
            setCalls.append(on)
            return PowerHelperStatus(
                helperBuild: "1", sleepDisabled: on, setByHelper: on,
                holderCount: on ? 1 : 0, callerIsHolder: on
            )
        }
        func status() async throws -> PowerHelperStatus {
            PowerHelperStatus(
                helperBuild: "1", recoveryBlocked: recoveryBlocked,
                pendingRestore: pendingRestore, persistRetryNeeded: persistRetryNeeded
            )
        }
        func setSleepDisabledSynchronously(_ on: Bool, timeout: TimeInterval) -> Bool {
            syncCalls += 1
            setCalls.append(on)
            return true
        }
    }

    final class FakeLidObserver: LidStateObserving {
        var isClosed: Bool? = false
        var reading: LidClosedReading = .open
        var onChange: (() -> Void)?
        func start() {}
        func stop() {}
        func setPollingEnabled(_ enabled: Bool) {}
    }

    private func makeLidGuard(
        settings: SettingsStore,
        helper: FakeLidHelper = FakeLidHelper(),
        notifier: FakeNotifier
    ) -> LidSleepGuardController {
        LidSleepGuardController(
            settings: settings,
            helper: helper,
            lid: FakeLidObserver(),
            notifier: notifier,
            now: { 1_000 },
            e2eNamedInstance: false,
            sessionStore: LidClosedSessionStore(suiteName: "ka-lid-\(UUID().uuidString)"),
            sleepDisabledProbe: { nil },
            heartbeatInterval: 60
        )
    }

    private func makeController(
        assertions: FakeAssertions,
        settings: SettingsStore? = nil,
        powerSource: FakePowerSource? = nil,
        notifier: FakeNotifier? = nil,
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        agentActivity: AgentActivityMonitor? = nil,
        lidHelper: FakeLidHelper? = nil
    ) -> KeepAwakeController {
        let settings = settings
            ?? SettingsStore(defaults: UserDefaults(suiteName: "keep-awake-\(UUID().uuidString)")!)
        let notifier = notifier ?? FakeNotifier()
        let helper = lidHelper ?? FakeLidHelper()
        let monitor = agentActivity ?? AgentActivityMonitor(sources: [], processSampler: nil)
        // Disable optional sources so Agent-mode tests stay deterministic.
        settings.keepAwakeOrcaEnabled = false
        settings.keepAwakeDesktopAgentsEnabled = false
        settings.keepAwakeGrokBotEnabled = false
        return KeepAwakeController(
            settings: settings, displayManager: DisplayManager(settings: settings),
            agentActivity: monitor,
            lidGuard: makeLidGuard(settings: settings, helper: helper, notifier: notifier),
            powerSource: powerSource ?? FakePowerSource(),
            assertions: assertions,
            notifier: notifier,
            now: now
        )
    }

    @Test("Failed creation stays armed and the timer retries without claiming success")
    func retriesFailure() async throws {
        let assertions = FakeAssertions()
        assertions.failingTypes = [kIOPMAssertionTypePreventUserIdleDisplaySleep]
        let controller = makeController(assertions: assertions)
        defer { controller.shutdown() }
        controller.activate(.duration(seconds: 60))
        #expect(!controller.isHolding)
        #expect(controller.activationFailed)
        #expect(controller.mode == .duration(seconds: 60))

        assertions.failingTypes = []
        // Exercise the actual timer: previously it exited when isHolding was false.
        let deadline = ContinuousClock.now + .seconds(4)
        while !controller.isHolding, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(controller.isHolding)
        #expect(!controller.activationFailed)
    }

    @Test("A zero-valued ID is owned, healthy assertions stay held, and lost ones recover")
    func repairsLostAssertion() {
        let assertions = FakeAssertions()
        let controller = makeController(assertions: assertions)
        defer { controller.shutdown() }
        controller.activate(.indefinite)
        #expect(assertions.active[0] == kIOPMAssertionTypePreventUserIdleDisplaySleep)
        controller.reevaluate()
        #expect(assertions.nextID == 1)
        #expect(assertions.released.isEmpty)

        assertions.active = [:]
        controller.reevaluate()
        #expect(controller.isHolding)
        #expect(assertions.nextID == 2)
        #expect(assertions.released == [0])
        controller.deactivate()
        #expect(assertions.active.isEmpty)
        #expect(!controller.isHolding)
    }

    @Test("Partial success does not claim both requested protections are active")
    func partialFailure() {
        let assertions = FakeAssertions()
        assertions.failingTypes = [kIOPMAssertionTypePreventUserIdleSystemSleep]
        let controller = makeController(assertions: assertions)
        defer { controller.shutdown() }
        controller.alsoPreventSystemSleep = true
        controller.activate(.indefinite)
        #expect(!controller.isHolding)
        #expect(controller.activationFailed)
        #expect(assertions.active.count == 1)

        controller.alsoPreventSystemSleep = false
        #expect(controller.isHolding)
        #expect(!controller.activationFailed)
        #expect(assertions.nextID == 1)
    }

    @Test("Wake restores a missing assertion, but never extends an expired duration")
    func wakeAndExpiry() {
        let assertions = FakeAssertions()
        var time = 100.0
        let controller = makeController(assertions: assertions, now: { time })
        defer { controller.shutdown() }
        controller.activate(.duration(seconds: 60))
        assertions.active = [:]
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(controller.isHolding)
        #expect(assertions.active.count == 1)
        #expect(assertions.nextID == 2)

        time = 160
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(controller.mode == .off)
        #expect(!controller.isHolding)
        #expect(controller.remainingSeconds == nil)
        #expect(assertions.active.isEmpty)
    }

    @Test("Shutdown cancels retry work and wake notifications cannot reacquire assertions")
    func shutdownStopsRecovery() async throws {
        let assertions = FakeAssertions()
        let controller = makeController(assertions: assertions)
        controller.activate(.duration(seconds: 60))
        controller.shutdown()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(controller.mode == .off)
        #expect(!controller.isHolding)
        #expect(!controller.activationFailed)
        #expect(assertions.active.isEmpty)
        #expect(assertions.nextID == 1)
    }

    @Test("A waiting trigger is paused rather than reported as an assertion failure")
    func missingTrigger() {
        let assertions = FakeAssertions()
        let controller = makeController(assertions: assertions)
        defer { controller.shutdown() }
        controller.activate(.whileDisplayConnected(uuid: "absent"))
        #expect(!controller.isHolding)
        #expect(!controller.activationFailed)
        #expect(assertions.active.isEmpty)
        #expect(controller.mode == .whileDisplayConnected(uuid: "absent"))
    }

    @Test("Agent detection settings survive a rebuild — they live in the store, not in the controller")
    func agentDetectionSettingsPersist() {
        let defaults = UserDefaults(suiteName: "keep-awake-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        // 第二層預設開啟：沒有全域 log 的 agent 只靠它。
        #expect(settings.keepAwakeProcessDetection)
        #expect(settings.keepAwakeBatteryFloor == .percent20)

        let first = makeController(assertions: FakeAssertions(), settings: settings)
        first.agentProcessDetectionEnabled = false
        first.agentCustomProcessNames = ["aider", "goose"]
        first.batteryFloor = .percent10
        first.shutdown()

        let reloaded = SettingsStore(defaults: defaults)
        let second = makeController(assertions: FakeAssertions(), settings: reloaded)
        defer { second.shutdown() }
        #expect(!second.agentProcessDetectionEnabled)
        #expect(second.agentCustomProcessNames == ["aider", "goose"])
        #expect(second.batteryFloor == .percent10)
    }

    @Test("Real macOS assertions can be created, queried, and released")
    func systemAssertions() throws {
        let assertions = SystemKeepAwakeAssertions()
        for type in [kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionTypePreventUserIdleSystemSleep] {
            let id = try #require(assertions.create(type: type, reason: "Chorus keep awake regression test"))
            #expect(assertions.isActive(id))
            assertions.release(id)
            #expect(!assertions.isActive(id))
        }
    }

    @Test("Power floor releases assertions, notifies once, and reholds on recovery")
    func powerFloorPausesAndResumes() {
        let assertions = FakeAssertions()
        let power = FakePowerSource()
        let notifier = FakeNotifier()
        let controller = makeController(
            assertions: assertions, powerSource: power, notifier: notifier
        )
        defer { controller.shutdown() }
        controller.activate(.indefinite)
        #expect(controller.isHolding)
        #expect(power.started)
        #expect(notifier.paused.isEmpty)

        power.publish(PowerSnapshot(
            hasInternalBattery: true, onBattery: true, percent: 15, thermal: .nominal
        ))
        #expect(!controller.isHolding)
        #expect(controller.pauseReason == .lowBattery(percent: 15))
        #expect(assertions.active.isEmpty)
        #expect(notifier.paused == [.lowBattery(percent: 15)])
        #expect(controller.mode == .indefinite)

        power.publish(PowerSnapshot(
            hasInternalBattery: true, onBattery: true, percent: 14, thermal: .nominal
        ))
        #expect(notifier.paused.count == 1)

        power.publish(PowerSnapshot(
            hasInternalBattery: true, onBattery: false, percent: 14, thermal: .nominal
        ))
        #expect(controller.isHolding)
        #expect(controller.pauseReason == .ok)
        #expect(assertions.active.count == 1)
    }

    @Test("Duration mode keeps counting while paused by the power floor")
    func powerFloorDoesNotCancelDuration() {
        let assertions = FakeAssertions()
        let power = FakePowerSource()
        var time = 100.0
        let controller = makeController(
            assertions: assertions, powerSource: power, now: { time }
        )
        defer { controller.shutdown() }
        controller.activate(.duration(seconds: 60))
        #expect(controller.isHolding)

        power.publish(PowerSnapshot(
            hasInternalBattery: true, onBattery: true, percent: 10, thermal: .nominal
        ))
        #expect(!controller.isHolding)
        #expect(controller.mode == .duration(seconds: 60))
        #expect(controller.remainingSeconds == 60)

        time = 130
        controller.reevaluate()
        #expect(controller.mode == .duration(seconds: 60))
        #expect(controller.remainingSeconds == 30)
        #expect(!controller.isHolding)

        time = 160
        controller.reevaluate()
        #expect(controller.mode == .off)
        #expect(!power.started)
    }

    @Test("Power source monitoring stops when keep-awake turns off")
    func powerMonitorLifecycle() {
        let assertions = FakeAssertions()
        let power = FakePowerSource()
        let controller = makeController(assertions: assertions, powerSource: power)
        defer { controller.shutdown() }
        #expect(!power.started)
        controller.activate(.indefinite)
        #expect(power.started)
        controller.deactivate()
        #expect(!power.started)
        #expect(controller.pauseReason == .ok)
    }

    @Test("Working agents require display protection before reporting success and release it when idle")
    func agentDisplayProtection() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "agent-display-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appending(path: "session.jsonl")
        try Data("{}\n".utf8).write(to: log)
        let monitor = AgentActivityMonitor(
            sources: [ResolvedAgentLogSource(engine: "Codex", root: root)],
            processSampler: nil, pollInterval: .seconds(3600)
        )
        let assertions = FakeAssertions()
        assertions.failingTypes = [kIOPMAssertionTypePreventUserIdleDisplaySleep]
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "agent-display-\(UUID().uuidString)")!)
        settings.keepAwakeOrcaEnabled = false
        settings.keepAwakeDesktopAgentsEnabled = false
        settings.keepAwakeGrokBotEnabled = false
        let notifier = FakeNotifier()
        let controller = KeepAwakeController(
            settings: settings, displayManager: DisplayManager(settings: settings),
            agentActivity: monitor,
            lidGuard: makeLidGuard(settings: settings, notifier: notifier),
            assertions: assertions,
            notifier: notifier,
            workspaceNotifications: NotificationCenter()
        )
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        let deadline = ContinuousClock.now + .seconds(2)
        while !monitor.isWorking, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(monitor.isWorking)
        #expect(!controller.isHolding)
        #expect(controller.activationFailed)

        assertions.failingTypes = []
        controller.reevaluate()
        #expect(controller.isHolding)
        #expect(!controller.activationFailed)
        #expect(Set(assertions.active.values) == [
            kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionTypePreventUserIdleSystemSleep,
        ])

        try FileManager.default.removeItem(at: log)
        await monitor.refresh()
        #expect(!controller.isHolding)
        #expect(assertions.active.isEmpty)
    }

    @Test("Agent mode: hub busy (lease) drives IOPMAssertion (V-C08 / A4)")
    func hubBusyDrivesAssertion() async throws {
        let assertions = FakeAssertions()
        let controller = makeController(assertions: assertions)
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        #expect(!controller.isHolding)

        let result = controller.sourceHub.leases.hold(id: "lease-bot", ttl: 600)
        guard case .held = result else {
            Issue.record("expected held lease")
            return
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !controller.isHolding, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(controller.isHolding)
        #expect(controller.sourceHub.isBusy)
    }

    @Test("Non-agent mode keeps lidGuard off (V-C08)")
    func nonAgentLidOff() async throws {
        let helper = FakeLidHelper()
        let controller = makeController(assertions: FakeAssertions(), lidHelper: helper)
        defer { controller.shutdown() }
        controller.lidGuard.settings = LidSleepSettings(enabled: true)
        controller.activate(.indefinite)
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.lidGuard.phase == .off)
        #expect(helper.setCalls.filter { $0 }.isEmpty)
    }

    @Test("shutdown calls lidGuard before deactivate (V-C08)")
    func shutdownOrdersLidFirst() async throws {
        let helper = FakeLidHelper()
        let controller = makeController(assertions: FakeAssertions(), lidHelper: helper)
        controller.lidGuard.settings = LidSleepSettings(enabled: true)
        controller.activate(.whileAgentsWorking)
        _ = controller.sourceHub.leases.hold(id: "shutdown-order", ttl: 600)
        let deadline = ContinuousClock.now + .seconds(2)
        while helper.setCalls.filter({ $0 }).isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!helper.setCalls.filter({ $0 }).isEmpty)
        controller.shutdown()
        #expect(helper.syncCalls >= 1)
        #expect(controller.mode == .off)
        #expect(!controller.isHolding)
    }

    @Test("Option off never set(true); leftover probe still allowed (V-C08-5 / V-C08-7)")
    func optionOffNoSetTrue() async throws {
        let helper = FakeLidHelper()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "opt-off-\(UUID().uuidString)")!)
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: false)
        settings.keepAwakeOrcaEnabled = false
        settings.keepAwakeDesktopAgentsEnabled = false
        let notifier = FakeNotifier()
        let lidGuard = LidSleepGuardController(
            settings: settings,
            helper: helper,
            lid: FakeLidObserver(),
            notifier: notifier,
            now: { 1_000 },
            e2eNamedInstance: false,
            sessionStore: LidClosedSessionStore(suiteName: "opt-off-sess-\(UUID().uuidString)"),
            sleepDisabledProbe: { false },
            heartbeatInterval: 60
        )
        let controller = KeepAwakeController(
            settings: settings, displayManager: DisplayManager(settings: settings),
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            lidGuard: lidGuard,
            assertions: FakeAssertions(),
            notifier: notifier
        )
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        _ = controller.sourceHub.leases.hold(id: "x", ttl: 60)
        try await Task.sleep(for: .milliseconds(150))
        #expect(helper.setCalls.filter { $0 }.isEmpty)
        await lidGuard.detectLeftover()
        #expect(helper.setCalls.filter { $0 }.isEmpty)
    }

    private func decodeHold(_ response: AutomationHTTPTransport.Response) throws -> KeepAwakeHoldResponse {
        #expect(response.status == 200)
        let data = Data(response.json.utf8)
        return try JSONDecoder().decode(KeepAwakeHoldResponse.self, from: data)
    }

    private func holdBody(id: String, ttl: Double = 60) -> Data {
        Data(#"{"id":"\#(id)","ttl":\#(ttl)}"#.utf8)
    }

    @Test("C8-7 Agent + lidGuardOff + assertion fail → reason lidGuardOff")
    func holdReasonLidGuardOff() throws {
        let assertions = FakeAssertions()
        assertions.failingTypes = [
            kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionTypePreventUserIdleSystemSleep,
        ]
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "hold-off-\(UUID().uuidString)")!)
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: false)
        settings.keepAwakeOrcaEnabled = false
        settings.keepAwakeDesktopAgentsEnabled = false
        settings.keepAwakeGrokBotEnabled = false
        let controller = makeController(assertions: assertions, settings: settings)
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        let held = try decodeHold(controller.handleKeepAwakeHold(body: holdBody(id: "r-lid-off")))
        #expect(!held.assertionEffective)
        #expect(!held.lidEffective)
        #expect(!held.effective)
        #expect(held.reason == "lidGuardOff")
    }

    @Test("C8-7 Agent + lowBattery block + assertion fail → blocked:lowBattery")
    func holdReasonBlockedLowBattery() throws {
        let assertions = FakeAssertions()
        assertions.failingTypes = [
            kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionTypePreventUserIdleSystemSleep,
        ]
        let power = FakePowerSource()
        power.snapshot = PowerSnapshot(
            hasInternalBattery: true, onBattery: true, percent: 10, thermal: .nominal
        )
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "hold-batt-\(UUID().uuidString)")!)
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: true, batteryFloorPercent: 30)
        settings.keepAwakeOrcaEnabled = false
        settings.keepAwakeDesktopAgentsEnabled = false
        settings.keepAwakeGrokBotEnabled = false
        let helper = FakeLidHelper()
        let notifier = FakeNotifier()
        let lidGuard = makeLidGuard(settings: settings, helper: helper, notifier: notifier)
        let controller = KeepAwakeController(
            settings: settings,
            displayManager: DisplayManager(settings: settings),
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            lidGuard: lidGuard,
            powerSource: power,
            assertions: assertions,
            notifier: notifier
        )
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        let held = try decodeHold(controller.handleKeepAwakeHold(body: holdBody(id: "r-batt")))
        #expect(!held.assertionEffective)
        #expect(!held.lidEffective)
        #expect(held.reason == "blocked:lowBattery")
    }

    @Test("C8-7 Agent + lid enabled + assertion fail → blocked:assertionFailed")
    func holdReasonAssertionFailed() throws {
        let assertions = FakeAssertions()
        assertions.failingTypes = [
            kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionTypePreventUserIdleSystemSleep,
        ]
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "hold-assert-\(UUID().uuidString)")!)
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        settings.keepAwakeOrcaEnabled = false
        settings.keepAwakeDesktopAgentsEnabled = false
        settings.keepAwakeGrokBotEnabled = false
        // Helper not ready → lid unavailable, but lidGuardOff must not win when enabled.
        let helper = FakeLidHelper()
        helper.availability = .notRegistered
        let controller = makeController(assertions: assertions, settings: settings, lidHelper: helper)
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        let held = try decodeHold(controller.handleKeepAwakeHold(body: holdBody(id: "r-assert")))
        #expect(!held.assertionEffective)
        #expect(!held.lidEffective)
        #expect(held.reason == "blocked:assertionFailed")
    }

    @Test("C8-7 non-Agent hold → agentModeOff")
    func holdReasonAgentModeOff() throws {
        let controller = makeController(assertions: FakeAssertions())
        defer { controller.shutdown() }
        controller.activate(.indefinite)
        let held = try decodeHold(controller.handleKeepAwakeHold(body: holdBody(id: "r-mode")))
        #expect(!held.effective)
        #expect(held.reason == "agentModeOff")
    }

    @Test("C8-4 HTTP cached status exposes all recovery flags without a helper call")
    func statusExposesRecoveryEvidence() async throws {
        for flag in [0, 1, 2] {
            let settings = SettingsStore(defaults: UserDefaults(suiteName: "status-recovery-\(UUID().uuidString)")!)
            settings.keepAwakeLidGuard = LidSleepSettings(enabled: true)
            let helper = FakeLidHelper()
            helper.recoveryBlocked = flag == 0
            helper.pendingRestore = flag == 1
            helper.persistRetryNeeded = flag == 2
            let controller = makeController(assertions: FakeAssertions(), settings: settings, lidHelper: helper)
            defer { controller.shutdown() }
            controller.activate(.whileAgentsWorking)
            await controller.lidGuard.refreshFromHelper()
            _ = controller.handleKeepAwakeHold(body: holdBody(id: "recovery"))
            let response = controller.handleKeepAwakeStatus()
            let responseData = Data(response.json.utf8)
            let json = try #require(JSONSerialization.jsonObject(with: responseData) as? [String: Any])
            let cached = try #require(json["helper"] as? [String: Any])
            #expect(cached["recoveryBlocked"] as? Bool == (flag == 0))
            #expect(cached["pendingRestore"] as? Bool == (flag == 1))
            #expect(cached["persistRetryNeeded"] as? Bool == (flag == 2))
            #expect(json["lidPhase"] as? String == "unavailable")
            #expect(json["lidEffective"] as? Bool == false)
            #expect(helper.setCalls.isEmpty)
            // C01's current DTO must still decode the additive wire fields.
            _ = try JSONDecoder().decode(KeepAwakeStatusResponse.self, from: responseData)
        }
    }

    @Test("C8-7 partial: enabled but unavailable helper is explained without claiming option off")
    func holdReasonPartialHelperUnavailable() throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "hold-unavailable-r3-\(UUID().uuidString)")!)
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        let helper = FakeLidHelper()
        helper.availability = .notRegistered
        let controller = makeController(assertions: FakeAssertions(), settings: settings, lidHelper: helper)
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        let held = try decodeHold(controller.handleKeepAwakeHold(body: holdBody(id: "unavailable")))
        #expect(held.assertionEffective)
        #expect(!held.lidEffective)
        #expect(held.reason == "blocked:helperUnavailable")
    }

    @Test("C8-7 partial: assertion works + lidGuardOff → reason lidGuardOff")
    func holdReasonPartialLidGuardOff() async throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "hold-partial-lid-\(UUID().uuidString)")!)
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: false)
        settings.keepAwakeOrcaEnabled = false
        settings.keepAwakeDesktopAgentsEnabled = false
        settings.keepAwakeGrokBotEnabled = false
        let controller = makeController(assertions: FakeAssertions(), settings: settings)
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        let held = try decodeHold(controller.handleKeepAwakeHold(body: holdBody(id: "r-partial-lid")))
        #expect(held.assertionEffective)
        #expect(!held.lidEffective)
        #expect(held.effective)
        #expect(held.reason == "lidGuardOff")
    }

    @Test("C8-7 partial: assertion works + lid blocked noLid → blocked:noLid")
    func holdReasonPartialLidBlocked() async throws {
        // Lid noLid blocks arm; AC power keeps assertion power-floor clear (partial case).
        let power = FakePowerSource()
        power.snapshot = PowerSnapshot(
            hasInternalBattery: true, onBattery: false, percent: 80, thermal: .nominal
        )
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "hold-partial-nolid-\(UUID().uuidString)")!)
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        settings.keepAwakeOrcaEnabled = false
        settings.keepAwakeDesktopAgentsEnabled = false
        settings.keepAwakeGrokBotEnabled = false
        let helper = FakeLidHelper()
        let notifier = FakeNotifier()
        let lid = FakeLidObserver()
        lid.reading = .noLid
        let lidGuard = LidSleepGuardController(
            settings: settings,
            helper: helper,
            lid: lid,
            notifier: notifier,
            now: { 1_000 },
            e2eNamedInstance: false,
            sessionStore: LidClosedSessionStore(suiteName: "ka-nolid-\(UUID().uuidString)"),
            sleepDisabledProbe: { nil },
            heartbeatInterval: 60
        )
        let controller = KeepAwakeController(
            settings: settings,
            displayManager: DisplayManager(settings: settings),
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            lidGuard: lidGuard,
            powerSource: power,
            assertions: FakeAssertions(),
            notifier: notifier
        )
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        let held = try decodeHold(controller.handleKeepAwakeHold(body: holdBody(id: "r-partial-nolid")))
        #expect(held.assertionEffective)
        #expect(!held.lidEffective)
        #expect(held.effective)
        #expect(held.reason == "blocked:noLid")
    }

    @Test("C8-7 partial: assertion fails + lid holding → blocked:assertionFailed")
    func holdReasonPartialAssertionFailed() async throws {
        let assertions = FakeAssertions()
        assertions.failingTypes = [
            kIOPMAssertionTypePreventUserIdleDisplaySleep,
            kIOPMAssertionTypePreventUserIdleSystemSleep,
        ]
        let power = FakePowerSource()
        power.snapshot = PowerSnapshot(
            hasInternalBattery: true, onBattery: false, percent: 80, thermal: .nominal
        )
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "hold-partial-assert-\(UUID().uuidString)")!)
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        settings.keepAwakeOrcaEnabled = false
        settings.keepAwakeDesktopAgentsEnabled = false
        settings.keepAwakeGrokBotEnabled = false
        let helper = FakeLidHelper()
        let notifier = FakeNotifier()
        let lidGuard = makeLidGuard(settings: settings, helper: helper, notifier: notifier)
        let controller = KeepAwakeController(
            settings: settings,
            displayManager: DisplayManager(settings: settings),
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            lidGuard: lidGuard,
            powerSource: power,
            assertions: assertions,
            notifier: notifier
        )
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        // Drive lid hold via hub busy before sampling hold response.
        _ = controller.sourceHub.leases.hold(id: "seed-busy", ttl: 120)
        let armDeadline = ContinuousClock.now + .seconds(2)
        while !lidGuard.isActuallyHoldingSleepDisabled, ContinuousClock.now < armDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(lidGuard.isActuallyHoldingSleepDisabled)
        let held = try decodeHold(controller.handleKeepAwakeHold(body: holdBody(id: "r-partial-assert")))
        #expect(!held.assertionEffective)
        #expect(held.lidEffective)
        #expect(held.effective)
        #expect(held.reason == "blocked:assertionFailed")
    }
}
