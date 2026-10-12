import Foundation

/// `POST /v1/keepawake/hold` 請求（spec §4.5）。
public struct KeepAwakeHoldRequest: Codable, Sendable, Equatable {
    public var id: String
    public var ttl: Double?

    public init(id: String, ttl: Double? = nil) {
        self.id = id
        self.ttl = ttl
    }
}

/// `POST /v1/keepawake/hold` 回應。
///
/// Fi A4：分別提供 `assertionEffective`／`lidEffective`；
/// `effective` 保留為相容欄位（任一為 true 即 true）。
public struct KeepAwakeHoldResponse: Codable, Sendable, Equatable {
    public var id: String
    public var expiresIn: Double
    public var ttl: Double
    public var effective: Bool
    public var assertionEffective: Bool
    public var lidEffective: Bool
    public var reason: String?

    public init(
        id: String,
        expiresIn: Double,
        ttl: Double,
        assertionEffective: Bool,
        lidEffective: Bool,
        reason: String? = nil
    ) {
        self.id = id
        self.expiresIn = expiresIn
        self.ttl = ttl
        self.assertionEffective = assertionEffective
        self.lidEffective = lidEffective
        self.effective = assertionEffective || lidEffective
        self.reason = reason
    }
}

/// `POST /v1/keepawake/release` 請求。
public struct KeepAwakeReleaseRequest: Codable, Sendable, Equatable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

/// `POST /v1/keepawake/release` 回應。
public struct KeepAwakeReleaseResponse: Codable, Sendable, Equatable {
    public var id: String
    public var released: Bool

    public init(id: String, released: Bool) {
        self.id = id
        self.released = released
    }
}

/// 狀態回應中的租約摘要（wire DTO，不依賴 helper 型別）。
public struct KeepAwakeLeaseStatusDTO: Codable, Sendable, Equatable {
    public var id: String
    public var expiresIn: Double
    public var ttl: Double

    public init(id: String, expiresIn: Double, ttl: Double) {
        self.id = id
        self.expiresIn = expiresIn
        self.ttl = ttl
    }
}

/// Helper 狀態的獨立 wire DTO（C01 不依賴 C03 的 `PowerHelperStatus`）。
public struct KeepAwakeHelperStatusDTO: Codable, Sendable, Equatable {
    public var availability: String?
    public var sleepDisabled: Bool?
    public var setByHelper: Bool?
    public var holderCount: Int?
    public var callerIsHolder: Bool?
    public var otherUsersHolding: Bool?
    public var lastForcedOffReason: String?

    public init(
        availability: String? = nil,
        sleepDisabled: Bool? = nil,
        setByHelper: Bool? = nil,
        holderCount: Int? = nil,
        callerIsHolder: Bool? = nil,
        otherUsersHolding: Bool? = nil,
        lastForcedOffReason: String? = nil
    ) {
        self.availability = availability
        self.sleepDisabled = sleepDisabled
        self.setByHelper = setByHelper
        self.holderCount = holderCount
        self.callerIsHolder = callerIsHolder
        self.otherUsersHolding = otherUsersHolding
        self.lastForcedOffReason = lastForcedOffReason
    }
}

/// CLI `chorus keepawake …` 參數解析（C09；放 Core 以便 App 測試引用）。
public enum KeepAwakeCLIParser: Sendable {
    public enum Command: Equatable, Sendable {
        case hold(id: String, ttl: Double?)
        case release(id: String)
        case status
    }

    public enum ParseError: Error, Equatable, Sendable {
        case usage(String)
        case peerRejected
    }

    public static func parse(_ arguments: [String]) -> Result<Command, ParseError> {
        if arguments.contains("--peer") {
            return .failure(.peerRejected)
        }
        guard let verb = arguments.first else {
            return .failure(.usage("用法：chorus keepawake hold|release|status …"))
        }
        let rest = Array(arguments.dropFirst())
        switch verb {
        case "hold":
            return parseHold(rest)
        case "release":
            return parseRelease(rest)
        case "status":
            if rest.isEmpty { return .success(.status) }
            return .failure(.usage("用法：chorus keepawake status [--json]"))
        case "help", "-h", "--help":
            return .failure(.usage("用法：chorus keepawake hold|release|status …"))
        default:
            return .failure(.usage("未知的 keepawake 子指令「\(verb)」"))
        }
    }

    private static func parseHold(_ arguments: [String]) -> Result<Command, ParseError> {
        var args = arguments
        var id: String?
        var ttl: Double?
        while let flag = args.first {
            args.removeFirst()
            switch flag {
            case "--id":
                guard let value = args.first else {
                    return .failure(.usage("「--id」少了名稱"))
                }
                args.removeFirst()
                id = value
            case "--ttl":
                guard let value = args.first else {
                    return .failure(.usage("「--ttl」少了秒數"))
                }
                args.removeFirst()
                guard let parsed = Double(value), parsed.isFinite else {
                    return .failure(.usage("「--ttl」必須是數字"))
                }
                ttl = parsed
            default:
                return .failure(.usage("未知參數「\(flag)」"))
            }
        }
        guard let id else {
            return .failure(.usage("用法：chorus keepawake hold --id <name> [--ttl <秒>] [--json]"))
        }
        return .success(.hold(id: id, ttl: ttl))
    }

    private static func parseRelease(_ arguments: [String]) -> Result<Command, ParseError> {
        var args = arguments
        var id: String?
        while let flag = args.first {
            args.removeFirst()
            switch flag {
            case "--id":
                guard let value = args.first else {
                    return .failure(.usage("「--id」少了名稱"))
                }
                args.removeFirst()
                id = value
            default:
                return .failure(.usage("未知參數「\(flag)」"))
            }
        }
        guard let id else {
            return .failure(.usage("用法：chorus keepawake release --id <name> [--json]"))
        }
        return .success(.release(id: id))
    }
}

/// `GET /v1/keepawake` 回應（spec §4.5；wire 用獨立 DTO）。
public struct KeepAwakeStatusResponse: Codable, Sendable, Equatable {
    public var mode: String
    public var isHolding: Bool
    /// Lid phase 字串，例如 `"armed"`／`"idle"`；不引用 C02 型別。
    public var lidPhase: String?
    public var contributing: [KeepAwakeSourceReport]
    public var leases: [KeepAwakeLeaseStatusDTO]
    public var helper: KeepAwakeHelperStatusDTO?
    public var assertionEffective: Bool
    public var lidEffective: Bool

    public init(
        mode: String,
        isHolding: Bool,
        lidPhase: String? = nil,
        contributing: [KeepAwakeSourceReport] = [],
        leases: [KeepAwakeLeaseStatusDTO] = [],
        helper: KeepAwakeHelperStatusDTO? = nil,
        assertionEffective: Bool = false,
        lidEffective: Bool = false
    ) {
        self.mode = mode
        self.isHolding = isHolding
        self.lidPhase = lidPhase
        self.contributing = contributing
        self.leases = leases
        self.helper = helper
        self.assertionEffective = assertionEffective
        self.lidEffective = lidEffective
    }
}
