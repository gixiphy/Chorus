import ChorusCore
import Foundation
import Testing
@testable import Chorus

actor FakeSystemLoadSampler: SystemLoadSampling {
    private var queue: [SystemLoadSample] = []
    private var pending: CheckedContinuation<SystemLoadSample, Never>?
    private(set) var resetCount = 0
    private(set) var sampleCount = 0

    func enqueue(_ sample: SystemLoadSample) {
        if let pending {
            self.pending = nil
            pending.resume(returning: sample)
        } else {
            queue.append(sample)
        }
    }

    func sample(configuration: SystemLoadConfiguration) async -> SystemLoadSample {
        sampleCount += 1
        if !queue.isEmpty {
            return queue.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            pending = continuation
        }
    }

    func reset() async {
        resetCount += 1
        queue.removeAll()
        if let pending {
            self.pending = nil
            pending.resume(returning: SystemLoadSample(
                sampledAt: 0, cpu: .unavailable, gpu: .unsupported, network: .unavailable
            ))
        }
    }

    func resumePending(with sample: SystemLoadSample) {
        if let pending {
            self.pending = nil
            pending.resume(returning: sample)
        } else {
            queue.append(sample)
        }
    }
}

final class ManualDoubleClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _time: Double
    var time: Double {
        get { lock.lock(); defer { lock.unlock() }; return _time }
        set { lock.lock(); defer { lock.unlock() }; _time = newValue }
    }
    init(_ time: Double) { _time = time }
}

@MainActor
@Suite("SystemLoadMonitor")
struct SystemLoadMonitorTests {
    @Test func generationDropsInFlightAfterStop() async {
        let fake = FakeSystemLoadSampler()
        let clock = ManualDoubleClock(0)
        let monitor = SystemLoadMonitor(
            sampler: fake, now: { clock.time }, pollInterval: .milliseconds(5)
        )
        var holds = 0
        monitor.onDecisionChanged = { holds += 1 }

        monitor.start(configuration: .default)
        while await fake.sampleCount == 0 {
            try? await Task.sleep(for: .milliseconds(5))
        }
        monitor.stop()
        #expect(!monitor.evaluation.shouldHold)
        #expect(holds == 0)

        await fake.resumePending(with: SystemLoadSample(
            sampledAt: 15, cpu: .value(90), gpu: .unsupported, network: .value(0)
        ))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!monitor.evaluation.shouldHold)
    }

    @Test func evaluateAgesEvidenceWithoutNewSamples() {
        let monitor = SystemLoadMonitor(
            sampler: SystemLoadSampler(now: { 0 }),
            now: { 0 },
            pollInterval: .seconds(3600)
        )
        monitor.start(configuration: .default)
        monitor.stop()

        for t in [0.0, 5, 10, 15] {
            monitor.ingestForTesting(
                sample: SystemLoadSample(
                    sampledAt: t, cpu: .value(60), gpu: .unsupported, network: .value(0)
                ),
                now: t
            )
        }
        #expect(monitor.evaluation.shouldHold)

        monitor.ingestForTesting(sample: nil, now: 140)
        #expect(!monitor.evaluation.shouldHold)
    }
}

@MainActor
@Suite("KeepAwakeController load mode")
struct KeepAwakeLoadModeTests {
    final class FakeAssertions: KeepAwakeAsserting {
        var active: [IOPMAssertionID: String] = [:]
        var nextID: IOPMAssertionID = 0
        func create(type: String, reason: String) -> IOPMAssertionID? {
            let id = nextID
            nextID += 1
            active[id] = type
            return id
        }
        func isActive(_ id: IOPMAssertionID) -> Bool { active[id] != nil }
        func release(_ id: IOPMAssertionID) { active.removeValue(forKey: id) }
    }

    @Test func loadModeHoldsAfterQualificationAndDropsOnOff() async {
        let assertions = FakeAssertions()
        let fake = FakeSystemLoadSampler()
        let clock = ManualDoubleClock(0)
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "load-mode-\(UUID().uuidString)")!)
        let monitor = SystemLoadMonitor(
            sampler: fake, now: { clock.time }, pollInterval: .milliseconds(5)
        )
        let controller = KeepAwakeController(
            settings: settings,
            displayManager: DisplayManager(settings: settings),
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            systemLoad: monitor,
            assertions: assertions,
            now: { clock.time }
        )
        defer { controller.shutdown() }

        controller.activate(.whileSystemBusy)
        monitor.stop()
        for t in [0.0, 5, 10, 15] {
            clock.time = t
            monitor.ingestForTesting(
                sample: SystemLoadSample(
                    sampledAt: t, cpu: .value(60), gpu: .unsupported, network: .value(0)
                ),
                now: t
            )
            controller.reevaluate()
        }
        #expect(controller.isHolding)

        controller.activate(.off)
        #expect(!controller.isHolding)
        #expect(assertions.active.isEmpty)

        await fake.resumePending(with: SystemLoadSample(
            sampledAt: 20, cpu: .value(90), gpu: .unsupported, network: .value(0)
        ))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(controller.mode == .off)
        #expect(assertions.active.isEmpty)
    }

    @Test func selectModePersistsLoadFlagAndRestoreWorks() {
        let suite = "load-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsStore(defaults: defaults)
        let controller = KeepAwakeController(
            settings: settings,
            displayManager: DisplayManager(settings: settings),
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            systemLoad: SystemLoadMonitor(
                sampler: SystemLoadSampler(now: { 0 }),
                now: { 0 }
            ),
            assertions: FakeAssertions(),
            now: { 0 }
        )
        controller.selectMode(.whileSystemBusy)
        #expect(settings.keepAwakeSystemLoadMode)
        #expect(settings.keepAwakeDisplayUUID == nil)
        #expect(!settings.keepAwakeAgentMode)
        controller.shutdown()

        let restoredSettings = SettingsStore(defaults: defaults)
        let restored = KeepAwakeController(
            settings: restoredSettings,
            displayManager: DisplayManager(settings: restoredSettings),
            agentActivity: AgentActivityMonitor(sources: [], processSampler: nil),
            assertions: FakeAssertions(),
            now: { 0 }
        )
        restored.restoreSavedMode()
        #expect(restored.mode == .whileSystemBusy)
        restored.shutdown()
    }
}
