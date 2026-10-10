import Testing
@testable import ChorusCore

@Suite("AgentIdleBlankPolicy")
struct AgentIdleBlankTests {
    @Test("Blanks only when armed, holding, and idle past the threshold")
    func blanksWhenArmed() {
        #expect(
            AgentIdleBlankPolicy.decide(
                enabled: true, agentModeActive: true, holdingAssertion: true,
                idleSeconds: 300, thresholdSeconds: 300, isBlanked: false
            ) == .blank
        )
        #expect(
            AgentIdleBlankPolicy.decide(
                enabled: true, agentModeActive: true, holdingAssertion: true,
                idleSeconds: 299, thresholdSeconds: 300, isBlanked: false
            ) == .stay
        )
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
        #expect(
            AgentIdleBlankPolicy.decide(
                enabled: true, agentModeActive: true, holdingAssertion: true,
                idleSeconds: 0.1, thresholdSeconds: 300, isBlanked: true
            ) == .restore
        )
        #expect(
            AgentIdleBlankPolicy.decide(
                enabled: true, agentModeActive: true, holdingAssertion: true,
                idleSeconds: 10, thresholdSeconds: 300, isBlanked: true
            ) == .stay
        )
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
}
