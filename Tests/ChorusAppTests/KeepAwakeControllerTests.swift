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

        func refreshAvailability(reason: PowerHelperRefreshReason) async {}
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
        notifier: FakeNotifier,
        lid: FakeLidObserver = FakeLidObserver()
    ) -> LidSleepGuardController {
        LidSleepGuardController(
            settings: settings,
            helper: helper,
            lid: lid,
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

    @Test("V1-2／V1-11 reevaluate coalesce + status TTL", .timeLimit(.minutes(1)))
    func reevaluateReentryAndStatusTTL() async throws {
        let controller = makeController(assertions: FakeAssertions())
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        let hold = controller.handleKeepAwakeHold(
            body: try JSONEncoder().encode(KeepAwakeHoldRequest(id: "reentry", ttl: 90))
        )
        #expect(hold.status == 200)
        for _ in 0..<20 {
            controller.reevaluate()
        }
        #expect(controller.sourceHub.isBusy)
        let status = controller.handleKeepAwakeStatus()
        #expect(status.status == 200)
        let decoded = try JSONDecoder().decode(
            KeepAwakeStatusResponse.self, from: Data(status.json.utf8)
        )
        #expect(decoded.leases.first?.ttl == 90)
        #expect(decoded.leases.first?.id == "reentry")
    }

    @Test(
        "V1-7 production wake refreshes lease expiry before assertion/Lid evaluation",
        .timeLimit(.minutes(1))
    )
    func wakeRefreshesExpiredLeaseBeforeReevaluate() async throws {
        var continuous = 10_000.0
        let leases = KeepAwakeLeaseSource(
            graceSeconds: 300,
            wallNow: { Date(timeIntervalSince1970: continuous) },
            uptimeNow: { continuous }
        )
        // Long tick so periodic hub refresh cannot mask the missing wake step.
        let hub = KeepAwakeSourceHub(
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            leases: leases,
            tickInterval: .seconds(3_600)
        )
        let center = NotificationCenter()
        let assertions = FakeAssertions()
        let helper = FakeLidHelper()
        let notifier = FakeNotifier()
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "wake-lease-\(UUID().uuidString)")!)
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        settings.keepAwakeOrcaEnabled = false
        settings.keepAwakeDesktopAgentsEnabled = false
        settings.keepAwakeGrokBotEnabled = false
        let lidGuard = makeLidGuard(settings: settings, helper: helper, notifier: notifier)
        let controller = KeepAwakeController(
            settings: settings,
            displayManager: DisplayManager(settings: settings),
            agentActivity: hub.agentActivity,
            sourceHub: hub,
            lidGuard: lidGuard,
            assertions: assertions,
            notifier: notifier,
            now: { continuous },
            workspaceNotifications: center
        )
        defer { controller.shutdown() }

        controller.activate(.whileAgentsWorking)
        _ = controller.sourceHub.leases.hold(id: "ttl60", ttl: 60)
        #expect(controller.isHolding)
        #expect(controller.sourceHub.isBusy)

        let acquiresBeforeWake = helper.setCalls.filter { $0 }.count

        // Sleep past TTL + 300s grace without a hub tick — report stays stale until wake.
        continuous += 60 + 300 + 1
        center.post(name: NSWorkspace.didWakeNotification, object: nil)

        #expect(!controller.sourceHub.isBusy)
        #expect(!controller.isHolding)
        #expect(assertions.active.isEmpty)
        // Lid must not acquire from expired-only work before the next periodic tick.
        #expect(helper.setCalls.filter { $0 }.count == acquiresBeforeWake)
    }

    @Test("V01R3 production wake fails closed on lease clock failure", .timeLimit(.minutes(1)))
    func wakeClockFailureStopsWorkAndRejectsHold() throws {
        var continuous: Double? = 10_000
        let leases = KeepAwakeLeaseSource(continuousNow: { continuous })
        let hub = KeepAwakeSourceHub(
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            leases: leases, tickInterval: .seconds(3_600))
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "wake-clock-\(UUID().uuidString)")!)
        settings.keepAwakeOrcaEnabled = false
        settings.keepAwakeDesktopAgentsEnabled = false
        settings.keepAwakeGrokBotEnabled = false
        let center = NotificationCenter()
        let assertions = FakeAssertions()
        let notifier = FakeNotifier()
        let controller = KeepAwakeController(
            settings: settings, displayManager: DisplayManager(settings: settings),
            agentActivity: hub.agentActivity, sourceHub: hub,
            lidGuard: makeLidGuard(settings: settings, notifier: notifier),
            powerSource: FakePowerSource(), assertions: assertions, notifier: notifier,
            workspaceNotifications: center)
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        #expect(controller.handleKeepAwakeHold(body: holdBody(id: "before-clock-loss")).status == 200)
        #expect(controller.isHolding)
        continuous = nil
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(!controller.sourceHub.isBusy)
        #expect(!controller.isHolding)
        #expect(assertions.active.isEmpty)
        #expect(controller.handleKeepAwakeHold(body: holdBody(id: "bad-clock")).status == 503)
        continuous = 10_361
        hub.tick()
        #expect(!controller.sourceHub.isBusy)
        #expect(controller.handleKeepAwakeHold(body: holdBody(id: "fresh-clock")).status == 200)
    }

    @Test("V01R3 transport rejects stale release before real controller mutation", .timeLimit(.minutes(1)))
    func transportRotationPreservesNewControllerLease() async throws {
        @MainActor final class Gate {
            var continuation: CheckedContinuation<Void, Never>?
            var opened = false
            func wait() async {
                if !opened { await withCheckedContinuation { continuation = $0 } }
            }
            func release() { opened = true; continuation?.resume(); continuation = nil }
        }
        let controller = makeController(assertions: FakeAssertions())
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        let body = try JSONEncoder().encode(KeepAwakeReleaseRequest(id: "same-id"))
        _ = controller.handleKeepAwakeHold(body: holdBody(id: "same-id"))
        let gate = Gate()
        let transport = AutomationHTTPTransport(token: "old", handlers: .init(
            state: { .init(status: 200, json: "{}") },
            scenes: { .init(status: 200, json: "[]") },
            doctor: { .init(status: 200, json: "{}") },
            execute: { _, _ in .init(status: 200, json: "{}") }, eventStreamsActive: { _ in },
            keepAwakeHold: { data in MainActor.assumeIsolated { controller.handleKeepAwakeHold(body: data) } },
            keepAwakeRelease: { data in MainActor.assumeIsolated { controller.handleKeepAwakeRelease(body: data) } }
        ), keepAwakeMutationGates: .init(afterAdmissionBeforeMainActor: { await gate.wait() }))
        let stale = Task {
            await transport.executeKeepAwakeMutationProductionPathForTesting(bearer: "old", body: body, hold: false)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while gate.continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(gate.continuation != nil)
        transport.rotateKeepAwakeAuthorization(token: "new")
        controller.clearKeepAwakeLeases()
        _ = controller.handleKeepAwakeHold(body: holdBody(id: "same-id"))
        gate.release()
        #expect(await stale.value.status == 409)
        #expect(controller.sourceHub.leases.snapshot().active.first?.id == "same-id")
        let unauthorized = await transport.executeKeepAwakeMutationProductionPathForTesting(bearer: "old", body: body, hold: false)
        #expect(unauthorized.status == 401)
        let authorized = await transport.executeKeepAwakeMutationProductionPathForTesting(bearer: "new", body: body, hold: false)
        #expect(authorized.status == 200)
        #expect(controller.sourceHub.leases.snapshot().active.isEmpty)
    }

    // MARK: - Merged agent ∨ load mode

    private func makeMergedController(
        assertions: FakeAssertions = FakeAssertions(),
        settings: SettingsStore? = nil,
        systemLoad: SystemLoadMonitor? = nil,
        sourceHub: KeepAwakeSourceHub? = nil,
        lidHelper: FakeLidHelper? = nil,
        lid: FakeLidObserver = FakeLidObserver(),
        powerSource: FakePowerSource? = nil,
        idleBlanker: AgentIdleBlanker? = nil,
        now: @escaping @Sendable () -> Double = { 0 },
        workspaceNotifications: NotificationCenter = NotificationCenter()
    ) -> KeepAwakeController {
        let settings = settings
            ?? SettingsStore(defaults: UserDefaults(suiteName: "merge-ka-\(UUID().uuidString)")!)
        settings.keepAwakeOrcaEnabled = false
        settings.keepAwakeDesktopAgentsEnabled = false
        settings.keepAwakeGrokBotEnabled = false
        let notifier = FakeNotifier()
        let helper = lidHelper ?? FakeLidHelper()
        let hub = sourceHub ?? KeepAwakeSourceHub(
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            graceSeconds: 2,
            tickInterval: .seconds(3_600)
        )
        // Always fake the sampler — real hardware samples flake on busy CI machines.
        let monitor = systemLoad ?? SystemLoadMonitor(
            sampler: IdleSystemLoadSampler(),
            now: now,
            pollInterval: .seconds(60)
        )
        return KeepAwakeController(
            settings: settings,
            displayManager: DisplayManager(settings: settings),
            agentActivity: hub.agentActivity,
            sourceHub: hub,
            lidGuard: makeLidGuard(settings: settings, helper: helper, notifier: notifier, lid: lid),
            systemLoad: monitor,
            powerSource: powerSource ?? FakePowerSource(),
            idleBlanker: idleBlanker,
            assertions: assertions,
            notifier: notifier,
            now: now,
            workspaceNotifications: workspaceNotifications
        )
    }

    private func qualifyLoad(
        _ monitor: SystemLoadMonitor,
        clock: ManualDoubleClock,
        controller: KeepAwakeController,
        times: [Double] = [0, 5, 10, 15],
        cpu: Double = 60
    ) {
        monitor.stop()
        for t in times {
            clock.time = t
            monitor.ingestForTesting(
                sample: SystemLoadSample(
                    sampledAt: t, cpu: .value(cpu), gpu: .unsupported, network: .value(0)
                ),
                now: t
            )
            controller.reevaluate()
        }
    }

    @Test("Merged mode starts hub and systemLoad; off stops both")
    func mergedModeStartsBothMonitors() {
        let clock = ManualDoubleClock(0)
        let monitor = SystemLoadMonitor(
            sampler: IdleSystemLoadSampler(),
            now: { clock.time },
            pollInterval: .seconds(60)
        )
        let controller = makeMergedController(systemLoad: monitor, now: { clock.time })
        defer { controller.shutdown() }
        #expect(!controller.sourceHub.isRunning)
        #expect(!monitor.isRunning)
        controller.activate(.whileAgentsWorking)
        #expect(controller.sourceHub.isRunning)
        #expect(monitor.isRunning)
        controller.activate(.off)
        #expect(!controller.sourceHub.isRunning)
        #expect(!monitor.isRunning)
    }

    @Test("Load-only hold uses both assertions; Lid busy stays false")
    func loadOnlyHoldDoesNotArmLid() async {
        let assertions = FakeAssertions()
        let helper = FakeLidHelper()
        let clock = ManualDoubleClock(0)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "merge-load-\(UUID().uuidString)")!)
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        let monitor = SystemLoadMonitor(
            sampler: IdleSystemLoadSampler(),
            now: { clock.time },
            pollInterval: .seconds(60)
        )
        let controller = makeMergedController(
            assertions: assertions,
            settings: settings,
            systemLoad: monitor,
            lidHelper: helper,
            now: { clock.time }
        )
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        qualifyLoad(monitor, clock: clock, controller: controller)
        #expect(controller.isHolding)
        #expect(assertions.active.values.contains(kIOPMAssertionTypePreventUserIdleDisplaySleep))
        #expect(assertions.active.values.contains(kIOPMAssertionTypePreventUserIdleSystemSleep))
        #expect(!controller.sourceHub.isBusy)
        #expect(!helper.setCalls.contains(true))
    }

    @Test("Backup import: syncModeWithSettings starts the merged mode live")
    func syncModeAfterImportStartsMergedMode() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "merge-sync-\(UUID().uuidString)")!)
        let controller = makeMergedController(settings: settings)
        defer { controller.shutdown() }
        #expect(controller.mode == .off)
        settings.keepAwakeAgentMode = true // 匯入寫進 defaults
        controller.syncModeWithSettings()
        #expect(controller.mode == .whileAgentsWorking)
        #expect(controller.sourceHub.isRunning)
    }

    @Test("Backup import: legacy load flag also starts merged mode and normalizes flags")
    func syncModeAfterImportAbsorbsLegacyLoad() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "merge-sync2-\(UUID().uuidString)")!)
        let controller = makeMergedController(settings: settings)
        defer { controller.shutdown() }
        settings.keepAwakeSystemLoadMode = true
        controller.syncModeWithSettings()
        #expect(controller.mode == .whileAgentsWorking)
        #expect(settings.keepAwakeAgentMode)
        #expect(!settings.keepAwakeSystemLoadMode)
    }

    @Test("Backup import with all flags off stops a persisted mode but keeps timed holds")
    func syncModeAfterImportClearsPersistedModeOnly() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "merge-sync3-\(UUID().uuidString)")!)
        let controller = makeMergedController(settings: settings)
        defer { controller.shutdown() }
        controller.selectMode(.whileAgentsWorking)
        #expect(controller.mode == .whileAgentsWorking)
        settings.keepAwakeAgentMode = false
        controller.syncModeWithSettings()
        #expect(controller.mode == .off)

        controller.activate(.indefinite)
        controller.syncModeWithSettings()
        #expect(controller.mode == .indefinite)
    }

    @Test("Backup import does not restart an already-running merged mode")
    func syncModeAfterImportKeepsRunningMode() {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "merge-sync4-\(UUID().uuidString)")!)
        let clock = ManualDoubleClock(0)
        let controller = makeMergedController(settings: settings, now: { clock.time })
        defer { controller.shutdown() }
        controller.selectMode(.whileAgentsWorking)
        let started = controller.startedAt
        clock.time = 50
        controller.syncModeWithSettings()
        #expect(controller.startedAt == started)
    }

    @Test("Closed lid + enabled option: load-only hold never calls set(true)")
    func loadOnlyClosedLidNeverSetsSleepDisabled() async throws {
        let helper = FakeLidHelper()
        let lid = FakeLidObserver()
        lid.reading = .closed
        lid.isClosed = true
        let clock = ManualDoubleClock(0)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "merge-closed-\(UUID().uuidString)")!)
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        let monitor = SystemLoadMonitor(
            sampler: IdleSystemLoadSampler(), now: { clock.time }, pollInterval: .seconds(60)
        )
        let controller = makeMergedController(
            settings: settings, systemLoad: monitor, lidHelper: helper, lid: lid,
            now: { clock.time }
        )
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        qualifyLoad(monitor, clock: clock, controller: controller)
        #expect(controller.isHolding)
        #expect(!controller.sourceHub.isBusy)
        // Lid arming is asynchronous; give it ample time to (wrongly) act.
        try await Task.sleep(for: .milliseconds(400))
        #expect(!helper.setCalls.contains(true))
        #expect(!controller.lidGuard.wantsSleepDisabled)
    }

    @Test("Positive control: closed lid + agent lease does call set(true)")
    func agentClosedLidControlSetsSleepDisabled() async throws {
        let helper = FakeLidHelper()
        let lid = FakeLidObserver()
        lid.reading = .closed
        lid.isClosed = true
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "merge-closed-ctl-\(UUID().uuidString)")!)
        settings.keepAwakeLidGuard = LidSleepSettings(enabled: true)
        let controller = makeMergedController(settings: settings, lidHelper: helper, lid: lid)
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        _ = controller.sourceHub.leases.hold(id: "lease-closed", ttl: 120)
        controller.reevaluate()
        let deadline = ContinuousClock.now + .seconds(3)
        while !helper.setCalls.contains(true), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(helper.setCalls.contains(true))
    }

    @Test("Agent-only lease holds while load keeps sampling")
    func agentOnlyKeepsLoadSampling() async throws {
        let sampler = FakeSystemLoadSampler()
        let clock = ManualDoubleClock(0)
        let monitor = SystemLoadMonitor(
            sampler: sampler, now: { clock.time }, pollInterval: .milliseconds(5)
        )
        let controller = makeMergedController(systemLoad: monitor, now: { clock.time })
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        _ = controller.sourceHub.leases.hold(id: "lease-a", ttl: 120)
        controller.reevaluate()
        #expect(controller.isHolding)
        let deadline = ContinuousClock.now + .seconds(2)
        while await sampler.sampleCount == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await sampler.sampleCount >= 1)
        await sampler.resumePending(with: SystemLoadSample(
            sampledAt: 1, cpu: .value(0), gpu: .unsupported, network: .value(0)
        ))
    }

    @Test("OR release waits for both load cooldown and hub grace")
    func orReleaseWaitsForBothSides() {
        let clock = ManualDoubleClock(0)
        let wallBase = Date(timeIntervalSince1970: 1_000)
        let wallOffset = ManualDoubleClock(0)
        let leases = KeepAwakeLeaseSource(
            graceSeconds: 5,
            wallNow: { wallBase.addingTimeInterval(wallOffset.time) },
            uptimeNow: { clock.time }
        )
        let hub = KeepAwakeSourceHub(
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            leases: leases,
            graceSeconds: 5,
            tickInterval: .seconds(3_600),
            now: { wallBase.addingTimeInterval(wallOffset.time) }
        )
        var config = SystemLoadConfiguration.default
        config.activationSeconds = 5
        config.releaseSeconds = 30
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "merge-or-\(UUID().uuidString)")!)
        settings.keepAwakeSystemLoadConfiguration = config
        let monitor = SystemLoadMonitor(
            sampler: IdleSystemLoadSampler(),
            now: { clock.time },
            pollInterval: .seconds(60)
        )
        let controller = makeMergedController(
            settings: settings,
            systemLoad: monitor,
            sourceHub: hub,
            now: { clock.time }
        )
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)

        // Qualify load.
        monitor.stop()
        for t in [0.0, 5] {
            clock.time = t
            monitor.ingestForTesting(
                sample: SystemLoadSample(
                    sampledAt: t, cpu: .value(80), gpu: .unsupported, network: .value(0)
                ),
                now: t
            )
            controller.reevaluate()
        }
        #expect(monitor.evaluation.shouldHold)

        // Lease with long TTL so agent side stays workingNow while load cools.
        _ = controller.sourceHub.leases.hold(id: "both", ttl: 600)
        controller.reevaluate()
        #expect(controller.isHolding)
        #expect(controller.sourceHub.isBusy)

        // Load cools fully; agent lease still active → still holding.
        clock.time = 10
        monitor.ingestForTesting(
            sample: SystemLoadSample(
                sampledAt: 10, cpu: .value(5), gpu: .unsupported, network: .value(0)
            ),
            now: 10
        )
        clock.time = 40
        monitor.ingestForTesting(sample: nil, now: 40)
        controller.reevaluate()
        #expect(!monitor.evaluation.shouldHold)
        #expect(controller.sourceHub.isBusy)
        #expect(controller.isHolding)

        // Expire lease into grace: still holding.
        clock.time = 5 + 600 + 1
        wallOffset.time = 1
        hub.tick()
        controller.reevaluate()
        #expect(controller.sourceHub.isBusy)
        #expect(controller.isHolding)

        // Grace ends → both sides clear → release.
        wallOffset.time = 10
        hub.tick()
        controller.reevaluate()
        #expect(!controller.sourceHub.isBusy)
        #expect(!monitor.evaluation.shouldHold)
        #expect(!controller.isHolding)
    }

    @Test("OR release: clearing agent leaves load hold intact")
    func orReleaseLoadOutlastsAgent() {
        let clock = ManualDoubleClock(0)
        var config = SystemLoadConfiguration.default
        config.activationSeconds = 5
        config.releaseSeconds = 30
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "merge-or2-\(UUID().uuidString)")!)
        settings.keepAwakeSystemLoadConfiguration = config
        let monitor = SystemLoadMonitor(
            sampler: IdleSystemLoadSampler(),
            now: { clock.time },
            pollInterval: .seconds(60)
        )
        let controller = makeMergedController(
            settings: settings,
            systemLoad: monitor,
            now: { clock.time }
        )
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)

        qualifyLoad(monitor, clock: clock, controller: controller, times: [0, 5], cpu: 80)
        #expect(monitor.evaluation.shouldHold)
        #expect(controller.isHolding)

        _ = controller.sourceHub.leases.hold(id: "rev", ttl: 600)
        controller.reevaluate()
        #expect(controller.sourceHub.isBusy)

        // Drop agent immediately (no grace) — load alone must keep the hold.
        controller.sourceHub.leases.clearImmediately()
        controller.sourceHub.tick()
        controller.reevaluate()
        #expect(controller.sourceHub.isBusy == false)
        #expect(monitor.evaluation.shouldHold)
        #expect(controller.isHolding)

        clock.time = 10
        monitor.ingestForTesting(
            sample: SystemLoadSample(
                sampledAt: 10, cpu: .value(5), gpu: .unsupported, network: .value(0)
            ),
            now: 10
        )
        clock.time = 40
        monitor.ingestForTesting(
            sample: SystemLoadSample(
                sampledAt: 40, cpu: .value(5), gpu: .unsupported, network: .value(0)
            ),
            now: 40
        )
        controller.reevaluate()
        #expect(monitor.evaluation.shouldHold == false)
        #expect(controller.isHolding == false)
    }

    @Test("Restore matrix absorbs legacy load flag")
    func restoreMatrixMerged() {
        let suite = "merge-restore-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        for (agent, load) in [(true, false), (false, true), (true, true)] {
            defaults.set(agent, forKey: "chorus.keepAwake.agentMode")
            defaults.set(load, forKey: "chorus.keepAwake.systemLoadMode")
            defaults.removeObject(forKey: "chorus.keepAwake.displayUUID")
            defaults.removeObject(forKey: "chorus.keepAwake.appBundleID")
            let settings = SettingsStore(defaults: defaults)
            let controller = makeMergedController(settings: settings)
            controller.restoreSavedMode()
            #expect(controller.mode == .whileAgentsWorking)
            #expect(settings.keepAwakeAgentMode)
            #expect(!settings.keepAwakeSystemLoadMode)
            controller.shutdown()
        }

        defaults.set(false, forKey: "chorus.keepAwake.agentMode")
        defaults.set(true, forKey: "chorus.keepAwake.systemLoadMode")
        defaults.set("DISP", forKey: "chorus.keepAwake.displayUUID")
        let displaySettings = SettingsStore(defaults: defaults)
        let displayController = makeMergedController(settings: displaySettings)
        displayController.restoreSavedMode()
        #expect(displayController.mode == .whileDisplayConnected(uuid: "DISP"))
        #expect(!displaySettings.keepAwakeAgentMode)
        displayController.shutdown()
    }

    @Test("willSleep stops load but keeps agent assertion")
    func willSleepKeepsAgentHold() {
        let center = NotificationCenter()
        let assertions = FakeAssertions()
        let clock = ManualDoubleClock(0)
        let monitor = SystemLoadMonitor(
            sampler: IdleSystemLoadSampler(),
            now: { clock.time },
            pollInterval: .seconds(60)
        )
        let controller = makeMergedController(
            assertions: assertions,
            systemLoad: monitor,
            now: { clock.time },
            workspaceNotifications: center
        )
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        _ = controller.sourceHub.leases.hold(id: "sleep-hold", ttl: 600)
        controller.reevaluate()
        #expect(controller.isHolding)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        #expect(!monitor.isRunning)
        #expect(controller.isHolding)
        #expect(!assertions.active.isEmpty)
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        #expect(monitor.isRunning)
        #expect(controller.isHolding)
    }

    @Test("applySystemLoadConfiguration live in merged mode only")
    func applyConfigLiveInMergedMode() {
        let clock = ManualDoubleClock(0)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "merge-cfg-\(UUID().uuidString)")!)
        let monitor = SystemLoadMonitor(
            sampler: IdleSystemLoadSampler(),
            now: { clock.time },
            pollInterval: .seconds(60)
        )
        let controller = makeMergedController(
            settings: settings, systemLoad: monitor, now: { clock.time }
        )
        defer { controller.shutdown() }

        var config = SystemLoadConfiguration.default
        config.cpu.activation = 80
        config.cpu.release = 40
        controller.activate(.indefinite)
        controller.applySystemLoadConfiguration(config)
        #expect(settings.keepAwakeSystemLoadConfiguration.cpu.activation == 80)
        #expect(!monitor.isRunning)

        controller.activate(.whileAgentsWorking)
        #expect(monitor.isRunning)
        config.cpu.activation = 70
        config.cpu.release = 35
        controller.applySystemLoadConfiguration(config)
        #expect(settings.keepAwakeSystemLoadConfiguration.cpu.activation == 70)
        #expect(monitor.isRunning)
    }

    @Test("Idle blanker runs for load-only hold")
    func idleBlankerForLoadOnly() {
        let displays = AgentIdleBlankerTests.FakeDisplays()
        let idle = 600.0
        let blanker = AgentIdleBlanker(displays: displays, idleSeconds: { idle })
        let clock = ManualDoubleClock(0)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "merge-blank-\(UUID().uuidString)")!)
        settings.keepAwakeAgentIdleBlankEnabled = true
        settings.keepAwakeAgentIdleMinutes = .three
        let monitor = SystemLoadMonitor(
            sampler: IdleSystemLoadSampler(),
            now: { clock.time },
            pollInterval: .seconds(60)
        )
        let controller = makeMergedController(
            settings: settings,
            systemLoad: monitor,
            idleBlanker: blanker,
            now: { clock.time }
        )
        defer { controller.shutdown() }
        controller.agentIdleBlankEnabled = true
        controller.agentIdleBlankMinutes = .three
        controller.activate(.whileAgentsWorking)
        qualifyLoad(monitor, clock: clock, controller: controller)
        #expect(controller.isHolding)
        blanker.evaluateForTesting()
        #expect(blanker.isBlanked)
        #expect(displays.blankCalls == 1)
    }

    @Test("HTTP status for load-only hold reports whileAgentsWorking")
    func httpStatusLoadOnly() throws {
        let clock = ManualDoubleClock(0)
        let monitor = SystemLoadMonitor(
            sampler: IdleSystemLoadSampler(),
            now: { clock.time },
            pollInterval: .seconds(60)
        )
        let controller = makeMergedController(systemLoad: monitor, now: { clock.time })
        defer { controller.shutdown() }
        controller.activate(.whileAgentsWorking)
        qualifyLoad(monitor, clock: clock, controller: controller)
        #expect(controller.isHolding)
        let status = controller.handleKeepAwakeStatus()
        let decoded = try JSONDecoder().decode(
            KeepAwakeStatusResponse.self, from: Data(status.json.utf8)
        )
        #expect(decoded.mode == "whileAgentsWorking")
        #expect(decoded.assertionEffective == true)
        #expect(decoded.contributing.isEmpty)
    }
}
