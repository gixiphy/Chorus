import ChorusCore
import Foundation
import Observation

@MainActor
@Observable
final class SystemLoadMonitor {
    private(set) var evaluation: SystemLoadEvaluation
    private(set) var latestSample: SystemLoadSample?

    /// Fired only when `shouldHold` flips. Other UI state updates via Observation.
    @ObservationIgnored var onDecisionChanged: (() -> Void)?

    @ObservationIgnored private let sampler: any SystemLoadSampling
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var plannerState = SystemLoadActivityPlanner.State()
    @ObservationIgnored private var configuration = SystemLoadConfiguration.default
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var running = false

    init(
        sampler: any SystemLoadSampling = SystemLoadSampler(),
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        pollInterval: Duration = .seconds(5)
    ) {
        self.sampler = sampler
        self.now = now
        self.pollInterval = pollInterval
        self.evaluation = SystemLoadEvaluation(
            phase: .waiting, shouldHold: false, qualifiedSignals: [], cooldownRemaining: nil
        )
    }

    func start(configuration: SystemLoadConfiguration) {
        let config = configuration.normalized()
        generation &+= 1
        let token = generation
        running = true
        self.configuration = config
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.sampler.reset()
            guard !Task.isCancelled, self.generation == token else { return }
            while !Task.isCancelled {
                guard self.generation == token, self.running else { return }
                let captured = self.configuration
                let sample = await self.sampler.sample(configuration: captured)
                guard !Task.isCancelled, self.generation == token, self.running else { return }
                self.apply(sample: sample, now: self.now())
                try? await Task.sleep(for: self.pollInterval)
            }
        }
    }

    /// Stops polling and clears state. Does **not** call `onDecisionChanged`
    /// (caller reevaluates next).
    func stop() {
        generation &+= 1
        running = false
        pollTask?.cancel()
        pollTask = nil
        plannerState = SystemLoadActivityPlanner.State()
        latestSample = nil
        evaluation = SystemLoadEvaluation(
            phase: .waiting, shouldHold: false, qualifiedSignals: [], cooldownRemaining: nil
        )
    }

    /// Health tick: age evidence without reading hardware.
    func evaluate(now: Double) {
        guard running else { return }
        apply(sample: nil, now: now)
    }

    /// Test seam: feed a sample through the planner without waiting on the poll loop.
    func ingestForTesting(sample: SystemLoadSample?, now: Double) {
        if !running {
            running = true
            configuration = configuration.normalized()
        }
        apply(sample: sample, now: now)
    }

    /// After sleep: clear baselines / latches and restart sampling if still armed.
    func resetAfterWake() {
        guard running else { return }
        let config = configuration
        start(configuration: config)
    }

    func applyConfiguration(_ configuration: SystemLoadConfiguration) {
        let config = configuration.normalized()
        self.configuration = config
        guard running else { return }
        start(configuration: config)
    }

    /// Display topology change: drop unsupported cache and restart sampling.
    func invalidateGPUCapability() {
        guard running else { return }
        Task {
            if let sampler = sampler as? SystemLoadSampler {
                await sampler.invalidateGPUCapability()
            }
            let config = configuration
            await MainActor.run { self.start(configuration: config) }
        }
    }

    // MARK: - Internals

    private func apply(sample: SystemLoadSample?, now: Double) {
        let previousHold = evaluation.shouldHold
        let stepped = SystemLoadActivityPlanner.step(
            plannerState, sample: sample, configuration: configuration, now: now
        )
        plannerState = stepped.state
        evaluation = stepped.evaluation
        if let sample { latestSample = sample }
        if evaluation.shouldHold != previousHold {
            onDecisionChanged?()
        }
    }
}
