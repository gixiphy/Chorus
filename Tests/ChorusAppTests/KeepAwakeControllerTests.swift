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

    private func makeController(
        assertions: FakeAssertions,
        settings: SettingsStore? = nil,
        powerSource: FakePowerSource? = nil,
        notifier: FakeNotifier? = nil,
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) -> KeepAwakeController {
        let settings = settings
            ?? SettingsStore(defaults: UserDefaults(suiteName: "keep-awake-\(UUID().uuidString)")!)
        return KeepAwakeController(
            settings: settings, displayManager: DisplayManager(settings: settings),
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            powerSource: powerSource ?? FakePowerSource(),
            assertions: assertions,
            notifier: notifier ?? FakeNotifier(),
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
        let controller = KeepAwakeController(
            settings: settings, displayManager: DisplayManager(settings: settings),
            agentActivity: monitor, assertions: assertions,
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
}
