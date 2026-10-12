import Foundation

/// Helper XPC 常數與協定（spec §6.2）。requirement 字串逐字照 spec。
public enum PowerHelperConstants {
    public static let machServiceName = "com.hermes.Chorus.PowerHelper"
    public static let daemonPlistName = "com.hermes.Chorus.PowerHelper.plist"
    public static let protocolVersion = 1
    public static let teamID = "2ENEDJHX95"
    /// helper 用它驗證呼叫端（App）
    public static let clientRequirement =
        #"identifier "com.hermes.Chorus" and anchor apple generic and certificate leaf[subject.OU] = "2ENEDJHX95""#
    /// App 用它驗證 helper（雙向）
    public static let helperRequirement =
        #"identifier "com.hermes.Chorus.PowerHelper" and anchor apple generic and certificate leaf[subject.OU] = "2ENEDJHX95""#
    public static let heartbeatInterval: Double = 20
    public static let watchdogTimeout: Double = 60
    public static let idleExitDelay: Double = 30
}

/// 只有兩個方法。set(true) 同時是心跳。
@objc(ChorusPowerHelperXPC)
public protocol ChorusPowerHelperXPC {
    func setSleepDisabled(
        _ enabled: Bool,
        withReply reply: @escaping (_ statusJSON: Data?, _ errorCode: String?) -> Void
    )
    func status(withReply reply: @escaping (_ statusJSON: Data) -> Void)
}

public struct PowerHelperStatus: Codable, Sendable, Equatable {
    public var protocolVersion: Int
    public var helperBuild: String
    public var sleepDisabled: Bool?
    public var setByHelper: Bool
    public var priorValueWasDisabled: Bool?
    public var holderCount: Int
    public var callerIsHolder: Bool
    public var otherUsersHolding: Bool
    public var watchdogSeconds: Int
    public var lastForcedOffReason: String?
    public var lastChangeAt: Date?

    public init(
        protocolVersion: Int = PowerHelperConstants.protocolVersion,
        helperBuild: String,
        sleepDisabled: Bool? = nil,
        setByHelper: Bool = false,
        priorValueWasDisabled: Bool? = nil,
        holderCount: Int = 0,
        callerIsHolder: Bool = false,
        otherUsersHolding: Bool = false,
        watchdogSeconds: Int = Int(PowerHelperConstants.watchdogTimeout),
        lastForcedOffReason: String? = nil,
        lastChangeAt: Date? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.helperBuild = helperBuild
        self.sleepDisabled = sleepDisabled
        self.setByHelper = setByHelper
        self.priorValueWasDisabled = priorValueWasDisabled
        self.holderCount = holderCount
        self.callerIsHolder = callerIsHolder
        self.otherUsersHolding = otherUsersHolding
        self.watchdogSeconds = watchdogSeconds
        self.lastForcedOffReason = lastForcedOffReason
        self.lastChangeAt = lastChangeAt
    }
}

public enum PMSetOutputParser {
    /// 解析 `pmset -g` 輸出中的 SleepDisabled。
    /// - 找到 1／0 → 對應 Bool
    /// - 完整可辨識輸出但沒有這一行 → false（未設定時 pmset 不列出）
    /// - 空字串或無法辨識 → nil（§14.1：不能當成 0）
    public static func sleepDisabled(fromPMSetG output: String) -> Bool? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // 至少要看起來像 pmset -g：含已知區塊關鍵字之一
        let recognizable = trimmed.contains("Sleep")
            || trimmed.contains("Hibernate")
            || trimmed.contains("disk")
            || trimmed.contains("displaysleep")
            || trimmed.contains("System-wide")
            || trimmed.contains("Currently")
        guard recognizable else { return nil }

        for line in trimmed.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0.isWhitespace })
            guard let first = parts.first, first == "SleepDisabled" else { continue }
            guard let last = parts.last else { return nil }
            if last == "1" { return true }
            if last == "0" { return false }
            return nil
        }
        return false
    }
}
