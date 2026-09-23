import Foundation
import Testing
@testable import ChorusCore

@Suite("SystemLoadActivityPlanner")
struct SystemLoadActivityPlannerTests {
    private let config = SystemLoadConfiguration.default

    @Test func cpuRequiresFifteenSecondsAndExpiresWithoutSamples() {
        var state = SystemLoadActivityPlanner.State()
        for t in [0.0, 5, 10, 15] {
            let result = SystemLoadActivityPlanner.step(
                state,
                sample: SystemLoadSample(
                    sampledAt: t, cpu: .value(60),
                    gpu: .unsupported, network: .value(0)
                ),
                configuration: config, now: t
            )
            state = result.state
            #expect(result.evaluation.shouldHold == (t == 15))
        }
        let cooling = SystemLoadActivityPlanner.step(state, sample: nil, configuration: config, now: 134)
        #expect(cooling.evaluation.shouldHold)
        #expect(cooling.evaluation.phase == .coolingDown)
        let expired = SystemLoadActivityPlanner.step(cooling.state, sample: nil, configuration: config, now: 135)
        #expect(!expired.evaluation.shouldHold)
    }

    @Test func eachSignalQualifiesIndependently() {
        for signal in SystemLoadSignal.allCases {
            var state = SystemLoadActivityPlanner.State()
            for t in [0.0, 5, 10, 15] {
                let result = SystemLoadActivityPlanner.step(
                    state,
                    sample: sample(at: t, high: signal),
                    configuration: config, now: t
                )
                state = result.state
                #expect(result.evaluation.shouldHold == (t == 15), "signal \(signal) at t=\(t)")
                if t == 15 {
                    #expect(result.evaluation.qualifiedSignals == [signal])
                    #expect(result.evaluation.phase == .active)
                }
            }
        }
    }

    @Test func activationBoundaryIsInclusiveAtFifteen() {
        var state = SystemLoadActivityPlanner.State()
        for t in [0.0, 5, 10] {
            let result = SystemLoadActivityPlanner.step(
                state, sample: highCPU(at: t), configuration: config, now: t
            )
            state = result.state
            #expect(!result.evaluation.shouldHold)
        }
        let almost = SystemLoadActivityPlanner.step(
            state, sample: highCPU(at: 14.999), configuration: config, now: 14.999
        )
        #expect(!almost.evaluation.shouldHold)
        let exact = SystemLoadActivityPlanner.step(
            almost.state, sample: highCPU(at: 15), configuration: config, now: 15
        )
        #expect(exact.evaluation.shouldHold)
    }

    @Test func activationAndReleaseThresholdsAreInclusive() {
        var state = SystemLoadActivityPlanner.State()
        // Qualify at exactly 50%.
        for t in [0.0, 5, 10, 15] {
            let result = SystemLoadActivityPlanner.step(
                state,
                sample: SystemLoadSample(
                    sampledAt: t, cpu: .value(50), gpu: .unsupported, network: .value(0)
                ),
                configuration: config, now: t
            )
            state = result.state
        }
        let held = SystemLoadActivityPlanner.step(
            state,
            sample: SystemLoadSample(
                sampledAt: 20, cpu: .value(50), gpu: .unsupported, network: .value(0)
            ),
            configuration: config, now: 20
        )
        #expect(held.evaluation.shouldHold)

        // Sustain at exactly 30%.
        let sustain = SystemLoadActivityPlanner.step(
            held.state,
            sample: SystemLoadSample(
                sampledAt: 25, cpu: .value(30), gpu: .unsupported, network: .value(0)
            ),
            configuration: config, now: 25
        )
        #expect(sustain.evaluation.shouldHold)
        #expect(sustain.evaluation.qualifiedSignals.contains(.cpu))
    }

    @Test func fortyNinePercentResetsCandidate() {
        var state = SystemLoadActivityPlanner.State()
        for t in [0.0, 5, 10] {
            let result = SystemLoadActivityPlanner.step(
                state, sample: highCPU(at: t), configuration: config, now: t
            )
            state = result.state
            #expect(result.evaluation.phase == .qualifying || t == 0)
        }
        let drop = SystemLoadActivityPlanner.step(
            state,
            sample: SystemLoadSample(
                sampledAt: 15, cpu: .value(49), gpu: .unsupported, network: .value(0)
            ),
            configuration: config, now: 15
        )
        #expect(!drop.evaluation.shouldHold)
        #expect(drop.evaluation.phase == .waiting)
    }

    @Test func fortyPercentSustainsAfterQualified() {
        var state = qualifyCPU()
        let sustain = SystemLoadActivityPlanner.step(
            state,
            sample: SystemLoadSample(
                sampledAt: 20, cpu: .value(40), gpu: .unsupported, network: .value(0)
            ),
            configuration: config, now: 20
        )
        #expect(sustain.evaluation.shouldHold)
        #expect(sustain.evaluation.qualifiedSignals == [.cpu])
    }

    @Test func alternatingSignalsDoNotCombineQualification() {
        var state = SystemLoadActivityPlanner.State()
        let sequence: [(Double, SystemLoadSignal)] = [
            (0, .cpu), (5, .gpu), (10, .network), (15, .cpu),
        ]
        for (t, signal) in sequence {
            let result = SystemLoadActivityPlanner.step(
                state, sample: sample(at: t, high: signal), configuration: config, now: t
            )
            state = result.state
            #expect(!result.evaluation.shouldHold, "must not hold at t=\(t)")
        }
    }

    @Test func afterCooldownMustReaccumulate() {
        var state = qualifyCPU()
        // Age out evidence and expire cooldown.
        let expired = SystemLoadActivityPlanner.step(state, sample: nil, configuration: config, now: 15 + 120)
        #expect(!expired.evaluation.shouldHold)
        state = expired.state

        for t in [140.0, 145, 150] {
            let result = SystemLoadActivityPlanner.step(
                state, sample: highCPU(at: t), configuration: config, now: t
            )
            state = result.state
            #expect(!result.evaluation.shouldHold)
        }
        let again = SystemLoadActivityPlanner.step(
            state, sample: highCPU(at: 155), configuration: config, now: 155
        )
        #expect(again.evaluation.shouldHold)
    }

    @Test func sampleGapOfFifteenKeepsChainAndFifteenPointOneResets() {
        var state = SystemLoadActivityPlanner.State()
        state = SystemLoadActivityPlanner.step(
            state, sample: highCPU(at: 0), configuration: config, now: 0
        ).state
        let okGap = SystemLoadActivityPlanner.step(
            state, sample: highCPU(at: 15), configuration: config, now: 15
        )
        // Gap exactly 15 is allowed; coverage from 0→15 qualifies.
        #expect(okGap.evaluation.shouldHold)

        state = SystemLoadActivityPlanner.State()
        state = SystemLoadActivityPlanner.step(
            state, sample: highCPU(at: 0), configuration: config, now: 0
        ).state
        let reset = SystemLoadActivityPlanner.step(
            state, sample: highCPU(at: 15.001), configuration: config, now: 15.001
        )
        #expect(!reset.evaluation.shouldHold)
        #expect(reset.evaluation.phase == .qualifying)
    }

    @Test func duplicateRewoundAndFutureSamplesAreIgnored() {
        var state = SystemLoadActivityPlanner.State()
        state = SystemLoadActivityPlanner.step(
            state, sample: highCPU(at: 5), configuration: config, now: 5
        ).state
        let dup = SystemLoadActivityPlanner.step(
            state, sample: highCPU(at: 5), configuration: config, now: 5
        )
        #expect(dup.evaluation.phase == .qualifying || dup.evaluation.phase == .waiting)

        let rewound = SystemLoadActivityPlanner.step(
            dup.state, sample: highCPU(at: 4), configuration: config, now: 6
        )
        #expect(!rewound.evaluation.shouldHold)

        let future = SystemLoadActivityPlanner.step(
            rewound.state, sample: highCPU(at: 100), configuration: config, now: 10
        )
        #expect(!future.evaluation.shouldHold)
    }

    @Test func nowGoingBackwardsResetsState() {
        var state = qualifyCPU()
        let reset = SystemLoadActivityPlanner.step(
            state, sample: nil, configuration: config, now: 1
        )
        #expect(!reset.evaluation.shouldHold)
        #expect(reset.evaluation.phase == .waiting || reset.evaluation.phase == .unavailable)
    }

    @Test func invalidNumericReadingsBecomeUnavailable() {
        var state = SystemLoadActivityPlanner.State()
        for (label, reading) in [
            ("nan", SystemLoadReading.value(.nan)),
            ("inf", SystemLoadReading.value(.infinity)),
            ("neg", SystemLoadReading.value(-1)),
            ("101", SystemLoadReading.value(101)),
        ] as [(String, SystemLoadReading)] {
            let result = SystemLoadActivityPlanner.step(
                state,
                sample: SystemLoadSample(
                    sampledAt: 0, cpu: reading, gpu: .unsupported, network: .value(0)
                ),
                configuration: config, now: 0
            )
            #expect(!result.evaluation.shouldHold, Comment(rawValue: label))
            #expect(result.evaluation.qualifiedSignals.isEmpty, Comment(rawValue: label))
            state = SystemLoadActivityPlanner.State()
        }
    }

    @Test func unsupportedGPUOnlyIsUnavailablePhase() {
        var config = SystemLoadConfiguration.default
        config.cpuEnabled = false
        config.networkEnabled = false
        config.gpuEnabled = true

        var state = SystemLoadActivityPlanner.State()
        let result = SystemLoadActivityPlanner.step(
            state,
            sample: SystemLoadSample(
                sampledAt: 0, cpu: .unavailable, gpu: .unsupported, network: .unavailable
            ),
            configuration: config, now: 0
        )
        #expect(result.evaluation.phase == .unavailable)
        #expect(!result.evaluation.shouldHold)
    }

    @Test func nilSampleHeartbeatOnlyAgesEvidence() {
        var state = qualifyCPU()
        let mid = SystemLoadActivityPlanner.step(state, sample: nil, configuration: config, now: 20)
        // Still within 15s freshness of last sample at t=15.
        #expect(mid.evaluation.shouldHold)
        #expect(mid.evaluation.phase == .active)
        #expect(mid.state.lastSustainedAt == 15)

        let cooling = SystemLoadActivityPlanner.step(mid.state, sample: nil, configuration: config, now: 31)
        #expect(cooling.evaluation.shouldHold)
        #expect(cooling.evaluation.phase == .coolingDown)
        #expect(cooling.state.lastSustainedAt == 15)
    }

    @Test func recoveringSourceCanQualifyAgain() {
        var state = SystemLoadActivityPlanner.State()
        state = SystemLoadActivityPlanner.step(
            state,
            sample: SystemLoadSample(
                sampledAt: 0, cpu: .unavailable, gpu: .unsupported, network: .value(0)
            ),
            configuration: config, now: 0
        ).state
        for t in [5.0, 10, 15, 20] {
            let result = SystemLoadActivityPlanner.step(
                state, sample: highCPU(at: t), configuration: config, now: t
            )
            state = result.state
            #expect(result.evaluation.shouldHold == (t == 20))
        }
    }

    // MARK: - Helpers

    private func highCPU(at t: Double) -> SystemLoadSample {
        SystemLoadSample(sampledAt: t, cpu: .value(60), gpu: .unsupported, network: .value(0))
    }

    private func sample(at t: Double, high: SystemLoadSignal) -> SystemLoadSample {
        SystemLoadSample(
            sampledAt: t,
            cpu: high == .cpu ? .value(60) : .value(0),
            gpu: high == .gpu ? .value(60) : .unsupported,
            network: high == .network ? .value(2_000_000) : .value(0)
        )
    }

    private func qualifyCPU() -> SystemLoadActivityPlanner.State {
        var state = SystemLoadActivityPlanner.State()
        for t in [0.0, 5, 10, 15] {
            state = SystemLoadActivityPlanner.step(
                state, sample: highCPU(at: t), configuration: config, now: t
            ).state
        }
        return state
    }
}
