import ChorusCore
import Foundation

protocol SystemLoadSampling: Sendable {
    func sample(configuration: SystemLoadConfiguration) async -> SystemLoadSample
    func reset() async
}

actor SystemLoadSampler: SystemLoadSampling {
    private let now: @Sendable () -> Double
    private let cpuReader: SystemCPUReader
    private let networkReader: SystemNetworkReader
    private let gpuReader: SystemGPUReader

    /// Optional hooks for tests that count reader invocations.
    private let cpuReadHook: (@Sendable () -> CPUTicks?)?
    private let networkReadHook: (@Sendable () -> [NetworkInterfaceCounters]?)?
    private let gpuReadHook: (@Sendable (_ forceProbe: Bool, _ previouslyUnsupported: Bool) -> SystemGPUReadResult)?

    private var previousCPU: CPUTicks?
    private var previousNetwork: [NetworkInterfaceCounters]?
    private var previousSampleAt: Double?
    private var gpuUnsupported = false

    init(now: @escaping @Sendable () -> Double = {
        ProcessInfo.processInfo.systemUptime
    }) {
        self.now = now
        self.cpuReader = SystemCPUReader()
        self.networkReader = SystemNetworkReader()
        self.gpuReader = SystemGPUReader()
        self.cpuReadHook = nil
        self.networkReadHook = nil
        self.gpuReadHook = nil
    }

    /// Test seam with injectable readers / clock.
    init(
        now: @escaping @Sendable () -> Double,
        cpuReader: SystemCPUReader = SystemCPUReader(),
        networkReader: SystemNetworkReader = SystemNetworkReader(),
        gpuReader: SystemGPUReader = SystemGPUReader(),
        cpuReadHook: (@Sendable () -> CPUTicks?)? = nil,
        networkReadHook: (@Sendable () -> [NetworkInterfaceCounters]?)? = nil,
        gpuReadHook: (@Sendable (_ forceProbe: Bool, _ previouslyUnsupported: Bool) -> SystemGPUReadResult)? = nil
    ) {
        self.now = now
        self.cpuReader = cpuReader
        self.networkReader = networkReader
        self.gpuReader = gpuReader
        self.cpuReadHook = cpuReadHook
        self.networkReadHook = networkReadHook
        self.gpuReadHook = gpuReadHook
    }

    func sample(configuration: SystemLoadConfiguration) async -> SystemLoadSample {
        let config = configuration.normalized()
        let sampledAt = now()

        // Long gap → rebuild baselines so a long idle average is not treated as current load.
        if let previousSampleAt, sampledAt - previousSampleAt > 15 {
            previousCPU = nil
            previousNetwork = nil
        }

        let cpu = config.cpuEnabled ? readCPU(sampledAt: sampledAt) : .unavailable
        let network = config.networkEnabled ? readNetwork(sampledAt: sampledAt) : .unavailable
        let gpuResult: SystemGPUReadResult
        if config.gpuEnabled {
            let start = ContinuousClock.now
            gpuResult = gpuReadHook?(false, gpuUnsupported)
                ?? gpuReader.read(forceProbe: false, previouslyUnsupported: gpuUnsupported)
            OperationMetrics.shared.record(
                "load.sample.gpu",
                elapsed: ContinuousClock.now - start
            )
            if case .unsupported = gpuResult.reading {
                gpuUnsupported = true
            }
        } else {
            gpuResult = SystemGPUReadResult(reading: .unavailable, partialSupport: false)
        }

        previousSampleAt = sampledAt
        return SystemLoadSample(
            sampledAt: sampledAt,
            cpu: cpu,
            gpu: gpuResult.reading,
            network: network,
            gpuPartialSupport: gpuResult.partialSupport
        )
    }

    func reset() async {
        previousCPU = nil
        previousNetwork = nil
        previousSampleAt = nil
        gpuUnsupported = false
    }

    /// Re-probe GPU after wake / display topology change.
    func invalidateGPUCapability() {
        gpuUnsupported = false
    }

    // MARK: - Readers

    private func readCPU(sampledAt: Double) -> SystemLoadReading {
        let start = ContinuousClock.now
        defer {
            OperationMetrics.shared.record("load.sample.cpu", elapsed: ContinuousClock.now - start)
        }
        guard let current = cpuReadHook?() ?? cpuReader.read() else {
            previousCPU = nil
            return .unavailable
        }
        defer { previousCPU = current }
        guard let previous = previousCPU else { return .unavailable }
        guard let delta = SystemLoadDelta.cpu(previous: previous, current: current) else {
            previousCPU = current
            return .unavailable
        }
        return .value(delta)
    }

    private func readNetwork(sampledAt: Double) -> SystemLoadReading {
        let start = ContinuousClock.now
        defer {
            OperationMetrics.shared.record(
                "load.sample.network",
                elapsed: ContinuousClock.now - start
            )
        }
        guard let current = networkReadHook?() ?? networkReader.read() else {
            previousNetwork = nil
            return .unavailable
        }
        let previous = previousNetwork
        previousNetwork = current

        guard let previous else {
            // First sample / all new baselines → unavailable (not 0).
            return .unavailable
        }
        let elapsed: Double
        if let previousSampleAt {
            elapsed = sampledAt - previousSampleAt
        } else {
            return .unavailable
        }
        guard let rate = SystemLoadDelta.network(
            previous: previous, current: current, elapsed: elapsed
        ) else {
            return .unavailable
        }
        return .value(rate)
    }
}
