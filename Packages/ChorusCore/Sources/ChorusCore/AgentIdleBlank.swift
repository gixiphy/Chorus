import Foundation

/// Agent 模式閒置熄屏的等候時間（分鐘）。
public enum KeepAwakeAgentIdleMinutes: Int, Sendable, Codable, CaseIterable, Equatable, Hashable {
    case three = 3
    case five = 5
    case ten = 10
    case fifteen = 15

    public static let `default` = KeepAwakeAgentIdleMinutes.five
}

/// 閒置熄屏決策。
public enum AgentIdleBlankDecision: Sendable, Equatable {
    case stay
    case blank
    case restore
}

public enum AgentIdleBlankPolicy {
    /// 熄屏後，閒置秒數低於此值視為「有輸入」，立即恢復。
    public static let activityResumeSeconds: Double = 0.5

    /// 純函式：依持有狀態、閒置秒數與目前是否已熄屏決定下一步。
    public static func decide(
        enabled: Bool,
        agentModeActive: Bool,
        holdingAssertion: Bool,
        idleSeconds: Double,
        thresholdSeconds: Double,
        isBlanked: Bool
    ) -> AgentIdleBlankDecision {
        let armed = enabled && agentModeActive && holdingAssertion
        if isBlanked {
            if !armed { return .restore }
            if idleSeconds < activityResumeSeconds { return .restore }
            return .stay
        }
        if armed && idleSeconds >= thresholdSeconds {
            return .blank
        }
        return .stay
    }
}
