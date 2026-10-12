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
    /// Ledger recovery health for verified unregister (W1-6 / §14.1).
    public var recoveryBlocked: Bool
    public var pendingRestore: Bool
    public var persistRetryNeeded: Bool

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
        lastChangeAt: Date? = nil,
        recoveryBlocked: Bool = false,
        pendingRestore: Bool = false,
        persistRetryNeeded: Bool = false
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
        self.recoveryBlocked = recoveryBlocked
        self.pendingRestore = pendingRestore
        self.persistRetryNeeded = persistRetryNeeded
    }

    enum CodingKeys: String, CodingKey {
        case protocolVersion, helperBuild, sleepDisabled, setByHelper
        case priorValueWasDisabled, holderCount, callerIsHolder, otherUsersHolding
        case watchdogSeconds, lastForcedOffReason, lastChangeAt
        case recoveryBlocked, pendingRestore, persistRetryNeeded
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        helperBuild = try c.decode(String.self, forKey: .helperBuild)
        sleepDisabled = try c.decodeIfPresent(Bool.self, forKey: .sleepDisabled)
        setByHelper = try c.decode(Bool.self, forKey: .setByHelper)
        priorValueWasDisabled = try c.decodeIfPresent(Bool.self, forKey: .priorValueWasDisabled)
        holderCount = try c.decode(Int.self, forKey: .holderCount)
        callerIsHolder = try c.decode(Bool.self, forKey: .callerIsHolder)
        otherUsersHolding = try c.decode(Bool.self, forKey: .otherUsersHolding)
        watchdogSeconds = try c.decode(Int.self, forKey: .watchdogSeconds)
        lastForcedOffReason = try c.decodeIfPresent(String.self, forKey: .lastForcedOffReason)
        lastChangeAt = try c.decodeIfPresent(Date.self, forKey: .lastChangeAt)
        recoveryBlocked = try c.decodeIfPresent(Bool.self, forKey: .recoveryBlocked) ?? false
        pendingRestore = try c.decodeIfPresent(Bool.self, forKey: .pendingRestore) ?? false
        persistRetryNeeded = try c.decodeIfPresent(Bool.self, forKey: .persistRetryNeeded) ?? false
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

        guard let rows = parseValidatedRows(trimmed) else { return nil }

        var seen: Bool?
        for row in rows where row.key == "SleepDisabled" {
            let value: Bool
            switch row.value {
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

    private struct SettingRow: Equatable {
        var key: String
        var value: String
    }

    /// 嚴格標頭＋列文法；失敗回 nil。
    ///
    /// 完整輸出：至少一條合法標頭列，且 ≥1 條合法已知設定列；任何無法驗證的列 → nil。
    /// 精簡文法（無標頭）：每一非空列都必須是合法已知設定列，且
    /// （含 SleepDisabled）或（≥2 列）。不得靠 substring 僞標頭過關。
    private static func parseValidatedRows(_ text: String) -> [SettingRow]? {
        let lines = text.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }

        guard !lines.isEmpty else { return nil }

        var hasHeader = false
        var rows: [SettingRow] = []
        var otherLineCount = 0

        for line in lines {
            if isHeaderLine(line) {
                hasHeader = true
                continue
            }
            switch classifySettingLine(line) {
            case .valid(let row):
                rows.append(row)
            case .malformedKnownKey:
                return nil
            case .other:
                otherLineCount += 1
            }
        }

        if hasHeader {
            // 標頭不能替未知／畸形列背書（例如 SleepDisabled: 1）。
            // 未確認的新系統格式保守回 nil，待有實機樣本再擴充文法。
            guard otherLineCount == 0, !rows.isEmpty else { return nil }
            return rows
        }

        // 精簡文法：禁止夾雜非設定列；不得用 contains 僞標頭
        guard otherLineCount == 0, !rows.isEmpty else { return nil }
        let hasSleepDisabled = rows.contains { $0.key == "SleepDisabled" }
        guard hasSleepDisabled || rows.count >= 2 else { return nil }
        return rows
    }

    private static func isHeaderLine(_ line: String) -> Bool {
        if line == "System-wide power settings:" {
            return true
        }
        return ["Currently on AC Power:", "Currently on Battery Power:", "Currently on UPS Power:"].contains(line)
    }

    private enum LineClass {
        case valid(SettingRow)
        case malformedKnownKey
        case other
    }

    private static func classifySettingLine(_ line: String) -> LineClass {
        let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let key = parts.first else { return .other }
        guard knownSettingKeys.contains(key) else { return .other }
        // 恰好兩欄：鍵 + 值；多餘 token、缺值、或值不符文法 → 畸形
        guard parts.count == 2, isValidSettingValue(key: key, value: parts[1]) else {
            return .malformedKnownKey
        }
        return .valid(SettingRow(key: key, value: parts[1]))
    }

    /// SleepDisabled 僅 0／1；路徑鍵允許以 `/` 開頭；其餘鍵為整數。
    private static func isValidSettingValue(key: String, value: String) -> Bool {
        if key == "SleepDisabled" {
            return value == "0" || value == "1"
        }
        if key == "hibernatefile" {
            return value.hasPrefix("/") && value.count > 1
        }
        return value.unicodeScalars.allSatisfy { CharacterSet.decimalDigits.contains($0) }
            && !value.isEmpty
    }
}
