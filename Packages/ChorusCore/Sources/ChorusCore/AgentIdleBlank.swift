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

/// 阻擋熄屏的訊號狀態：只有全部明確 inactive 才可熄屏。
public enum IdleBlankSignal: Sendable, Equatable {
    case active
    case inactive
    case unknown
}

/// 熄屏前的保護來源快照（媒體／全螢幕、遠端連線、外部 assertion）。
public struct AgentIdleBlankProtection: Sendable, Equatable {
    public var foreignDisplaySleepAssertion: IdleBlankSignal
    public var mediaOrFullscreen: IdleBlankSignal
    public var remoteSession: IdleBlankSignal

    public init(
        foreignDisplaySleepAssertion: IdleBlankSignal,
        mediaOrFullscreen: IdleBlankSignal,
        remoteSession: IdleBlankSignal
    ) {
        self.foreignDisplaySleepAssertion = foreignDisplaySleepAssertion
        self.mediaOrFullscreen = mediaOrFullscreen
        self.remoteSession = remoteSession
    }

    public static let allInactive = AgentIdleBlankProtection(
        foreignDisplaySleepAssertion: .inactive,
        mediaOrFullscreen: .inactive,
        remoteSession: .inactive
    )

    /// 任一來源 active 或 unknown → 不可新熄屏。
    public var blocksBlank: Bool {
        [foreignDisplaySleepAssertion, mediaOrFullscreen, remoteSession]
            .contains { $0 != .inactive }
    }

    /// 已熄屏時，明確 active 的保護來源應立即恢復螢幕。
    public var shouldRestoreWhileBlanked: Bool {
        [foreignDisplaySleepAssertion, mediaOrFullscreen, remoteSession]
            .contains { $0 == .active }
    }
}

public enum AgentIdleBlankPolicy {
    /// 熄屏後，閒置秒數低於此值視為「有輸入」，立即恢復。
    public static let activityResumeSeconds: Double = 0.5

    public static func isValidIdleSeconds(_ value: Double) -> Bool {
        value.isFinite && value >= 0
    }

    /// 純函式：依持有狀態、閒置秒數、保護訊號與目前是否已熄屏決定下一步。
    public static func decide(
        enabled: Bool,
        agentModeActive: Bool,
        holdingAssertion: Bool,
        idleSeconds: Double,
        thresholdSeconds: Double,
        isBlanked: Bool,
        protection: AgentIdleBlankProtection = .allInactive
    ) -> AgentIdleBlankDecision {
        let armed = enabled && agentModeActive && holdingAssertion
        let idleValid = isValidIdleSeconds(idleSeconds)

        if isBlanked {
            if !armed { return .restore }
            if idleValid && idleSeconds < activityResumeSeconds { return .restore }
            if protection.shouldRestoreWhileBlanked { return .restore }
            return .stay
        }

        guard armed, idleValid, idleSeconds >= thresholdSeconds else { return .stay }
        if protection.blocksBlank { return .stay }
        return .blank
    }
}
