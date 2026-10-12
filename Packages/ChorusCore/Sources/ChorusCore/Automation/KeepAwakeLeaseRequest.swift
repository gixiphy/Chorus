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
