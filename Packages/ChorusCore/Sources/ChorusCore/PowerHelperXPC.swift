import Foundation
import Security

/// Helper XPC 常數與協定（spec §6.2；Fi A6 覆寫 Release 簽章要求）。
public enum PowerHelperConstants {
    public static let machServiceName = "com.hermes.Chorus.PowerHelper"
    public static let daemonPlistName = "com.hermes.Chorus.PowerHelper.plist"
    public static let protocolVersion = 1
    public static let teamID = "2ENEDJHX95"

    /// Debug／開發互通：同 Team＋identifier 即可（含 Apple Development）。E24。
    public static let debugClientRequirement =
        #"identifier "com.hermes.Chorus" and anchor apple generic and certificate leaf[subject.OU] = "2ENEDJHX95""#

    /// Release helper 驗證呼叫端：Developer ID Application only，排除 get-task-allow（Fi A6／W0-5）。
    /// OID 1.2.840.113635.100.6.1.13 = Developer ID Application。
    public static let releaseClientRequirement =
        #"identifier "com.hermes.Chorus" and anchor apple generic and certificate leaf[subject.OU] = "2ENEDJHX95" and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and !(entitlement["com.apple.security.get-task-allow"] exists)"#

    /// 相容別名：預設指向 Debug 要求；C05 在 Release 必須改用 `releaseClientRequirement`。
    public static let clientRequirement = debugClientRequirement

    /// App 驗證 helper（雙向）。Release 發行時 helper 亦為 Developer ID。
    public static let debugHelperRequirement =
        #"identifier "com.hermes.Chorus.PowerHelper" and anchor apple generic and certificate leaf[subject.OU] = "2ENEDJHX95""#

    public static let releaseHelperRequirement =
        #"identifier "com.hermes.Chorus.PowerHelper" and anchor apple generic and certificate leaf[subject.OU] = "2ENEDJHX95" and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and !(entitlement["com.apple.security.get-task-allow"] exists)"#

    public static let helperRequirement = debugHelperRequirement

    /// 依建置組態選取 client requirement（C05 安裝用）。
    public static func clientRequirement(forRelease: Bool) -> String {
        forRelease ? releaseClientRequirement : debugClientRequirement
    }

    /// 依建置組態選取 helper requirement。
    public static func helperRequirement(forRelease: Bool) -> String {
        forRelease ? releaseHelperRequirement : debugHelperRequirement
    }

    /// 以公開 Security API 驗證 requirement 字串語法。
    @discardableResult
    public static func validateRequirementSyntax(_ requirement: String) -> Bool {
        var secReq: SecRequirement?
        let status = SecRequirementCreateWithString(requirement as CFString, [], &secReq)
        return status == errSecSuccess && secReq != nil
    }

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
    /// 已知的 `pmset -g` 設定鍵（完整輸出應至少出現若干列）。
    private static let knownSettingKeys: Set<String> = [
        "lidwake", "hibernatemode", "hibernatefile", "ttyskeepawake",
        "disksleep", "displaysleep", "sleep", "SleepDisabled", "powernap",
        "womp", "autorestart", "networkoversleep", "proximitywake",
        "tcpkeepalive", "acwake", "standby", "standbydelayhigh", "standbydelaylow",
        "highstandbythreshold", "gpuswitch", "halfdim", "lessbright",
    ]

    /// 解析 `pmset -g` 輸出中的 SleepDisabled。
    /// - 找到結構完整且唯一的 1／0 → 對應 Bool
    /// - 完整可辨識輸出但沒有這一行 → false（未設定時 pmset 不列出）
    /// - 截斷、衝突、畸形、無法辨識 → nil（§14.1／W0-6：不能當成 0 或 1）
    ///
    /// 呼叫端（C05）必須先確認行程 exit=0 且輸出未截斷，才把 stdout 交給本解析器。
    public static func sleepDisabled(fromPMSetG output: String) -> Bool? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        guard hasCompleteStructure(trimmed) else { return nil }

        var seen: Bool?
        for line in trimmed.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let first = parts.first, first == "SleepDisabled" else { continue }
            // 恰好兩欄：鍵 + 0/1；多餘 token 或垃圾 → nil
            guard parts.count == 2 else { return nil }
            let value: Bool
            switch parts[1] {
            case "1": value = true
            case "0": value = false
            default: return nil
            }
            if let prior = seen, prior != value {
                return nil // 衝突重複
            }
            seen = value
        }
        // 完整結構且無 SleepDisabled 列 → 視為未設定（false）
        return seen ?? false
    }

    /// 要求可辯護的完整輸出：標頭／區塊 + 至少一列已知設定鍵值。
    private static func hasCompleteStructure(_ text: String) -> Bool {
        let hasHeader = text.contains("System-wide power settings:")
            || text.contains("Currently on")
        guard hasHeader else {
            // 允許無標頭但含多列已知鍵的精簡樣本（測試用單行 SleepDisabled 需搭配其他鍵）
            return knownSettingLineCount(text) >= 2
                || (knownSettingLineCount(text) >= 1 && text.contains("SleepDisabled"))
        }
        // 僅有標頭、沒有任何設定列 → 截斷，回 nil
        return knownSettingLineCount(text) >= 1
    }

    private static func knownSettingLineCount(_ text: String) -> Int {
        var count = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let key = parts.first, knownSettingKeys.contains(key) else { continue }
            // 設定列至少要有鍵與一個值 token
            guard parts.count >= 2 else { continue }
            count += 1
        }
        return count
    }
}
