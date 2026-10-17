import Testing
@testable import ChorusCore

@Suite("AgentIdleBlankPolicy")
struct AgentIdleBlankTests {
    private let armed = (
        enabled: true,
        agentModeActive: true,
        holdingAssertion: true
    )

    private func decide(
        idleSeconds: Double,
        thresholdSeconds: Double = 300,
        isBlanked: Bool = false,
        protection: AgentIdleBlankProtection = .allInactive
    ) -> AgentIdleBlankDecision {
        AgentIdleBlankPolicy.decide(
            enabled: armed.enabled,
            agentModeActive: armed.agentModeActive,
            holdingAssertion: armed.holdingAssertion,
            idleSeconds: idleSeconds,
            thresholdSeconds: thresholdSeconds,
            isBlanked: isBlanked,
            protection: protection
        )
    }

    @Test("Blanks only when armed, holding, and idle past the threshold")
    func blanksWhenArmed() {
        #expect(decide(idleSeconds: 300, thresholdSeconds: 300) == .blank)
        #expect(decide(idleSeconds: 299, thresholdSeconds: 300) == .stay)
    }

    @Test("Disabled, non-agent, or not-holding never blanks")
    func neverBlanksWhenDisarmed() {
        let cases: [(Bool, Bool, Bool)] = [
            (false, true, true),
            (true, false, true),
            (true, true, false),
        ]
        for (enabled, agent, holding) in cases {
            #expect(
                AgentIdleBlankPolicy.decide(
                    enabled: enabled, agentModeActive: agent, holdingAssertion: holding,
                    idleSeconds: 999, thresholdSeconds: 60, isBlanked: false
                ) == .stay
            )
        }
    }

    @Test("Restores on user activity while blanked")
    func restoresOnActivity() {
        #expect(decide(idleSeconds: 0.1, isBlanked: true) == .restore)
        #expect(decide(idleSeconds: 10, isBlanked: true) == .stay)
    }

    @Test("Restores when leaving agent mode or dropping the assertion")
    func restoresWhenDisarmed() {
        #expect(
            AgentIdleBlankPolicy.decide(
                enabled: true, agentModeActive: false, holdingAssertion: true,
                idleSeconds: 999, thresholdSeconds: 300, isBlanked: true
            ) == .restore
        )
        #expect(
            AgentIdleBlankPolicy.decide(
                enabled: true, agentModeActive: true, holdingAssertion: false,
                idleSeconds: 999, thresholdSeconds: 300, isBlanked: true
            ) == .restore
        )
        #expect(
            AgentIdleBlankPolicy.decide(
                enabled: false, agentModeActive: true, holdingAssertion: true,
                idleSeconds: 999, thresholdSeconds: 300, isBlanked: true
            ) == .restore
        )
    }

    @Test(
        "Threshold truth table for 3/5/10/15 minutes",
        arguments: KeepAwakeAgentIdleMinutes.allCases
    )
    func thresholdMinutes(_ minutes: KeepAwakeAgentIdleMinutes) {
        let threshold = Double(minutes.rawValue * 60)
        #expect(decide(idleSeconds: threshold - 1, thresholdSeconds: threshold) == .stay)
        #expect(decide(idleSeconds: threshold, thresholdSeconds: threshold) == .blank)
        #expect(KeepAwakeAgentIdleMinutes.default == .five)
        #expect(KeepAwakeAgentIdleMinutes.allCases.contains(.three))
    }

    @Test("Foreign display-sleep assertion active blocks blank")
    func foreignAssertionBlocksBlank() {
        let protection = AgentIdleBlankProtection(
            foreignDisplaySleepAssertion: .active,
            mediaOrFullscreen: .inactive
        )
        #expect(decide(idleSeconds: 600, protection: protection) == .stay)
    }

    @Test("Foreground fullscreen / media protection active blocks blank")
    func fullscreenBlocksBlank() {
        let protection = AgentIdleBlankProtection(
            foreignDisplaySleepAssertion: .inactive,
            mediaOrFullscreen: .active
        )
        #expect(decide(idleSeconds: 600, protection: protection) == .stay)
    }

    @Test(
        "Any unknown protection source blocks blank",
        arguments: [
            AgentIdleBlankProtection(
                foreignDisplaySleepAssertion: .unknown,
                mediaOrFullscreen: .inactive
            ),
            AgentIdleBlankProtection(
                foreignDisplaySleepAssertion: .inactive,
                mediaOrFullscreen: .unknown
            ),
        ]
    )
    func unknownProtectionBlocksBlank(_ protection: AgentIdleBlankProtection) {
        #expect(decide(idleSeconds: 600, protection: protection) == .stay)
    }

    @Test(
        "Invalid idle never blanks; restores only when activity is confirmed",
        arguments: [Double.nan, -1.0, Double.infinity, -Double.infinity]
    )
    func invalidIdleIsConservative(_ idle: Double) {
        #expect(decide(idleSeconds: idle) == .stay)
        #expect(decide(idleSeconds: idle, isBlanked: true) == .stay)
        #expect(decide(idleSeconds: 0.1, isBlanked: true) == .restore)
    }

    @Test("While blanked, active media or foreign assertion restores immediately")
    func activeProtectionRestoresWhileBlanked() {
        let media = AgentIdleBlankProtection(
            foreignDisplaySleepAssertion: .inactive,
            mediaOrFullscreen: .active
        )
        let foreign = AgentIdleBlankProtection(
            foreignDisplaySleepAssertion: .active,
            mediaOrFullscreen: .inactive
        )
        #expect(decide(idleSeconds: 600, isBlanked: true, protection: media) == .restore)
        #expect(decide(idleSeconds: 600, isBlanked: true, protection: foreign) == .restore)
    }

    @Test("All blockers inactive still blanks at threshold")
    func allInactiveStillBlanks() {
        #expect(decide(idleSeconds: 300, protection: .allInactive) == .blank)
    }
}
