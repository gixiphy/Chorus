import Foundation

public enum SystemLoadSignal: String, CaseIterable, Codable, Sendable {
    case cpu, gpu, network
}

public enum SystemLoadReading: Sendable, Equatable {
    case value(Double)
    case unavailable
    case unsupported
}

public struct SystemLoadThreshold: Codable, Sendable, Equatable {
    public var activation: Double
    public var release: Double

    public init(activation: Double, release: Double) {
        self.activation = activation
        self.release = release
    }
}

public struct SystemLoadConfiguration: Codable, Sendable, Equatable {
    public var cpuEnabled: Bool
    public var gpuEnabled: Bool
    public var networkEnabled: Bool
    public var cpu: SystemLoadThreshold
    public var gpu: SystemLoadThreshold
    public var network: SystemLoadThreshold
    public var activationSeconds: Double
    public var releaseSeconds: Double

    public static let `default` = SystemLoadConfiguration(
        cpuEnabled: true,
        gpuEnabled: true,
        networkEnabled: true,
        cpu: SystemLoadThreshold(activation: 50, release: 30),
        gpu: SystemLoadThreshold(activation: 50, release: 30),
        network: SystemLoadThreshold(activation: 1_048_576, release: 262_144),
        activationSeconds: 15,
        releaseSeconds: 120
    )

    public init(
        cpuEnabled: Bool,
        gpuEnabled: Bool,
        networkEnabled: Bool,
        cpu: SystemLoadThreshold,
        gpu: SystemLoadThreshold,
        network: SystemLoadThreshold,
        activationSeconds: Double,
        releaseSeconds: Double
    ) {
        self.cpuEnabled = cpuEnabled
        self.gpuEnabled = gpuEnabled
        self.networkEnabled = networkEnabled
        self.cpu = cpu
        self.gpu = gpu
        self.network = network
        self.activationSeconds = activationSeconds
        self.releaseSeconds = releaseSeconds
    }

    public var isValid: Bool {
        Self.isPercentThresholdValid(cpu)
            && Self.isPercentThresholdValid(gpu)
            && Self.isNetworkThresholdValid(network)
            && Self.isDurationValid(activationSeconds, min: 5, max: 120)
            && Self.isDurationValid(releaseSeconds, min: 30, max: 600)
            && (cpuEnabled || gpuEnabled || networkEnabled)
    }

    public func normalized() -> Self {
        isValid ? self : .default
    }

    public func isEnabled(_ signal: SystemLoadSignal) -> Bool {
        switch signal {
        case .cpu: cpuEnabled
        case .gpu: gpuEnabled
        case .network: networkEnabled
        }
    }

    public func threshold(for signal: SystemLoadSignal) -> SystemLoadThreshold {
        switch signal {
        case .cpu: cpu
        case .gpu: gpu
        case .network: network
        }
    }

    private static func isPercentThresholdValid(_ threshold: SystemLoadThreshold) -> Bool {
        threshold.activation.isFinite
            && threshold.release.isFinite
            && threshold.release >= 0
            && threshold.activation <= 100
            && threshold.release < threshold.activation
    }

    private static func isNetworkThresholdValid(_ threshold: SystemLoadThreshold) -> Bool {
        let minActivation = 0.0625 * 1_048_576.0
        let maxRate = 1024.0 * 1_048_576.0
        return threshold.activation.isFinite
            && threshold.release.isFinite
            && threshold.activation >= minActivation
            && threshold.activation <= maxRate
            && threshold.release >= 0
            && threshold.release <= maxRate
            && threshold.release < threshold.activation
    }

    private static func isDurationValid(_ value: Double, min: Double, max: Double) -> Bool {
        guard value.isFinite, value >= min, value <= max else { return false }
        let steps = value / 5
        return abs(steps - steps.rounded()) < 1e-9
    }
}

public struct SystemLoadSample: Sendable, Equatable {
    public let sampledAt: Double
    public let cpu: SystemLoadReading
    public let gpu: SystemLoadReading
    public let network: SystemLoadReading
    public let gpuPartialSupport: Bool

    public init(
        sampledAt: Double,
        cpu: SystemLoadReading,
        gpu: SystemLoadReading,
        network: SystemLoadReading,
        gpuPartialSupport: Bool = false
    ) {
        self.sampledAt = sampledAt
        self.cpu = cpu
        self.gpu = gpu
        self.network = network
        self.gpuPartialSupport = gpuPartialSupport
    }

    public func reading(for signal: SystemLoadSignal) -> SystemLoadReading {
        switch signal {
        case .cpu: cpu
        case .gpu: gpu
        case .network: network
        }
    }
}

public enum SystemLoadPhase: String, Sendable {
    case waiting, qualifying, active, coolingDown, unavailable
}

public struct SystemLoadEvaluation: Sendable, Equatable {
    public let phase: SystemLoadPhase
    public let shouldHold: Bool
    public let qualifiedSignals: Set<SystemLoadSignal>
    public let cooldownRemaining: Double?

    public init(
        phase: SystemLoadPhase,
        shouldHold: Bool,
        qualifiedSignals: Set<SystemLoadSignal>,
        cooldownRemaining: Double?
    ) {
        self.phase = phase
        self.shouldHold = shouldHold
        self.qualifiedSignals = qualifiedSignals
        self.cooldownRemaining = cooldownRemaining
    }
}

public struct CPUTicks: Sendable, Equatable {
    public let user, system, nice, idle: UInt64

    public init(user: UInt64, system: UInt64, nice: UInt64, idle: UInt64) {
        self.user = user
        self.system = system
        self.nice = nice
        self.idle = idle
    }
}

public struct NetworkInterfaceCounters: Sendable, Equatable {
    public let index: UInt32
    public let name: String
    public let received, sent: UInt64

    public init(index: UInt32, name: String, received: UInt64, sent: UInt64) {
        self.index = index
        self.name = name
        self.received = received
        self.sent = sent
    }
}

public enum SystemLoadDelta {
    /// Busy percent over the interval: `100 * (Δuser+Δsystem+Δnice) / Δall`.
    /// Returns nil when counters regress or total delta is zero.
    public static func cpu(previous: CPUTicks, current: CPUTicks) -> Double? {
        guard current.user >= previous.user,
              current.system >= previous.system,
              current.nice >= previous.nice,
              current.idle >= previous.idle
        else { return nil }

        let busy = (current.user - previous.user)
            + (current.system - previous.system)
            + (current.nice - previous.nice)
        let idle = current.idle - previous.idle
        let total = busy + idle
        guard total > 0 else { return nil }
        return 100.0 * Double(busy) / Double(total)
    }

    /// Bytes/s across already-classified online physical interfaces.
    /// Empty `current` → 0. Online interfaces with no comparable baseline → nil.
    public static func network(
        previous: [NetworkInterfaceCounters],
        current: [NetworkInterfaceCounters],
        elapsed: Double
    ) -> Double? {
        guard elapsed.isFinite, elapsed > 0 else { return nil }
        if current.isEmpty { return 0 }

        let previousByKey = Dictionary(
            uniqueKeysWithValues: previous.map { (Self.key($0), $0) }
        )
        var totalBytes: UInt64 = 0
        var comparableCount = 0

        for iface in current {
            guard let prior = previousByKey[Self.key(iface)] else { continue }
            guard iface.received >= prior.received, iface.sent >= prior.sent else { continue }
            let delta = (iface.received - prior.received) + (iface.sent - prior.sent)
            totalBytes += delta
            comparableCount += 1
        }

        guard comparableCount > 0 else { return nil }
        return Double(totalBytes) / elapsed
    }

    private static func key(_ iface: NetworkInterfaceCounters) -> String {
        "\(iface.index):\(iface.name)"
    }
}
