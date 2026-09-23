import Foundation

public enum SystemLoadActivityPlanner {
    public struct State: Sendable {
        public init() {}

        var lastNow: Double?
        var lastAcceptedSampleAt: Double?
        var holding = false
        var lastSustainedAt: Double?
        var signals: [SystemLoadSignal: SignalState] = [
            .cpu: SignalState(),
            .gpu: SignalState(),
            .network: SignalState(),
        ]
    }

    struct SignalState: Sendable {
        var candidateSince: Double?
        var qualified = false
        var lastSampleAt: Double?
        /// Latest sanitized observation was `.unsupported`.
        var lastWasUnsupported = false
        /// Latest sanitized observation was a usable numeric value (not unavailable/unsupported).
        var lastWasValue = false
    }

    public static func step(
        _ state: State,
        sample: SystemLoadSample?,
        configuration: SystemLoadConfiguration,
        now: Double
    ) -> (state: State, evaluation: SystemLoadEvaluation) {
        var next = state
        let config = configuration.normalized()

        if let lastNow = next.lastNow, now < lastNow {
            next = State()
            return (next, makeEvaluation(next, configuration: config, now: now, freshSustain: false))
        }
        next.lastNow = now

        if let sample {
            apply(sample: sample, to: &next, configuration: config, now: now)
        }

        let qualified = freshQualifiedSignals(in: next, configuration: config, now: now)
        let freshSustain = !qualified.isEmpty
        if freshSustain {
            if let sustainedAt = qualified.compactMap({ next.signals[$0]?.lastSampleAt }).max() {
                next.lastSustainedAt = sustainedAt
            }
            next.holding = true
        } else if next.holding {
            if let last = next.lastSustainedAt, now < last + config.releaseSeconds {
                next.holding = true
            } else {
                next.holding = false
                next.lastSustainedAt = nil
            }
        }

        return (next, makeEvaluation(next, configuration: config, now: now, freshSustain: freshSustain))
    }

    // MARK: - Internals

    private static func apply(
        sample: SystemLoadSample,
        to state: inout State,
        configuration: SystemLoadConfiguration,
        now: Double
    ) {
        if let previous = state.lastAcceptedSampleAt, sample.sampledAt <= previous {
            return
        }
        if sample.sampledAt > now {
            return
        }

        state.lastAcceptedSampleAt = sample.sampledAt

        for signal in SystemLoadSignal.allCases {
            guard configuration.isEnabled(signal) else {
                state.signals[signal] = SignalState()
                continue
            }

            var signalState = state.signals[signal] ?? SignalState()
            let reading = sanitize(sample.reading(for: signal), signal: signal)

            switch reading {
            case .unsupported:
                signalState.candidateSince = nil
                signalState.qualified = false
                signalState.lastSampleAt = sample.sampledAt
                signalState.lastWasUnsupported = true
                signalState.lastWasValue = false
                state.signals[signal] = signalState
                continue

            case .unavailable:
                signalState.candidateSince = nil
                signalState.qualified = false
                signalState.lastSampleAt = sample.sampledAt
                signalState.lastWasUnsupported = false
                signalState.lastWasValue = false
                state.signals[signal] = signalState
                continue

            case .value(let value):
                if let last = signalState.lastSampleAt, sample.sampledAt - last > 15 {
                    signalState.candidateSince = nil
                    signalState.qualified = false
                }

                let threshold = configuration.threshold(for: signal)
                if signalState.qualified {
                    if value < threshold.release {
                        signalState.qualified = false
                        signalState.candidateSince = value >= threshold.activation
                            ? sample.sampledAt
                            : nil
                    }
                } else if value >= threshold.activation {
                    if signalState.candidateSince == nil {
                        signalState.candidateSince = sample.sampledAt
                    }
                    if let since = signalState.candidateSince,
                       sample.sampledAt - since >= configuration.activationSeconds {
                        signalState.qualified = true
                    }
                } else {
                    signalState.candidateSince = nil
                }

                signalState.lastSampleAt = sample.sampledAt
                signalState.lastWasUnsupported = false
                signalState.lastWasValue = true
                state.signals[signal] = signalState
            }
        }
    }

    private static func sanitize(_ reading: SystemLoadReading, signal: SystemLoadSignal) -> SystemLoadReading {
        switch reading {
        case .unavailable, .unsupported:
            return reading
        case .value(let value):
            guard value.isFinite else { return .unavailable }
            switch signal {
            case .cpu, .gpu:
                guard (0...100).contains(value) else { return .unavailable }
            case .network:
                guard value >= 0 else { return .unavailable }
            }
            return .value(value)
        }
    }

    private static func freshQualifiedSignals(
        in state: State,
        configuration: SystemLoadConfiguration,
        now: Double
    ) -> Set<SystemLoadSignal> {
        var result: Set<SystemLoadSignal> = []
        for signal in SystemLoadSignal.allCases {
            guard configuration.isEnabled(signal) else { continue }
            guard let signalState = state.signals[signal], signalState.qualified else { continue }
            guard let last = signalState.lastSampleAt, now - last <= 15 else { continue }
            result.insert(signal)
        }
        return result
    }

    private static func hasUsableMonitoringSource(
        state: State,
        configuration: SystemLoadConfiguration
    ) -> Bool {
        let enabled = SystemLoadSignal.allCases.filter { configuration.isEnabled($0) }
        guard !enabled.isEmpty else { return false }
        if state.lastAcceptedSampleAt == nil { return true }
        return enabled.contains { signal in
            guard let signalState = state.signals[signal] else { return true }
            return !signalState.lastWasUnsupported
        }
    }

    private static func makeEvaluation(
        _ state: State,
        configuration: SystemLoadConfiguration,
        now: Double,
        freshSustain: Bool
    ) -> SystemLoadEvaluation {
        let qualified = freshQualifiedSignals(in: state, configuration: configuration, now: now)
        let hasCandidate = SystemLoadSignal.allCases.contains { signal in
            guard configuration.isEnabled(signal) else { return false }
            let s = state.signals[signal]
            return s?.candidateSince != nil && !(s?.qualified ?? false)
        }
        let hasUsableSource = hasUsableMonitoringSource(state: state, configuration: configuration)

        let cooldownRemaining: Double?
        if state.holding, !freshSustain, let last = state.lastSustainedAt {
            cooldownRemaining = max(0, last + configuration.releaseSeconds - now)
        } else {
            cooldownRemaining = nil
        }

        let phase: SystemLoadPhase
        if !qualified.isEmpty {
            phase = .active
        } else if state.holding {
            phase = .coolingDown
        } else if !hasUsableSource {
            phase = .unavailable
        } else if hasCandidate {
            phase = .qualifying
        } else {
            phase = .waiting
        }

        return SystemLoadEvaluation(
            phase: phase,
            shouldHold: state.holding,
            qualifiedSignals: qualified,
            cooldownRemaining: cooldownRemaining
        )
    }
}
