import Foundation

/// 心跳租約表（spec §4.5）。時間使用 uptime；不持久化。
public struct KeepAwakeLeaseTable: Sendable, Equatable {
    public static let defaultTTL: Double = 600
    public static let ttlRange: ClosedRange<Double> = 30...3600
    public static let maxLeases = 32
    /// 與 busy 聚合器相同的寬限；tombstone 在此之後才真正移除。
    public static let defaultGraceSeconds: Double = AgentActivityPlanner.defaultGraceSeconds

    /// id 規則：`^[A-Za-z0-9._-]{1,64}$`
    public static func isValidID(_ id: String) -> Bool {
        guard (1...64).contains(id.count) else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9", ".", "_", "-":
                return true
            default:
                return false
            }
        }
    }

    public struct Lease: Sendable, Equatable {
        public var id: String
        public var expiresAt: Double
        public var firstHeldAt: Double
        public var lastHeartbeatAt: Double

        public init(id: String, expiresAt: Double, firstHeldAt: Double, lastHeartbeatAt: Double) {
            self.id = id
            self.expiresAt = expiresAt
            self.firstHeldAt = firstHeldAt
            self.lastHeartbeatAt = lastHeartbeatAt
        }
    }

    /// 已 release／到期、仍在 grace 內的跡證（供 report 使用；§14.3）。
    public struct Tombstone: Sendable, Equatable {
        public var id: String
        /// 到期或 release 時刻（uptime）。
        public var lastWorkingAt: Double

        public init(id: String, lastWorkingAt: Double) {
            self.id = id
            self.lastWorkingAt = lastWorkingAt
        }
    }

    public enum HoldResult: Equatable, Sendable {
        case held(expiresAt: Double, clampedTTL: Double)
        case invalidID
        case invalidTTL
        case tooMany
    }

    public private(set) var leases: [String: Lease] = [:]
    public private(set) var tombstones: [String: Tombstone] = [:]

    public init() {}

    public mutating func hold(id: String, ttl: Double?, now: Double) -> HoldResult {
        guard Self.isValidID(id) else { return .invalidID }

        let clampedTTL: Double
        if let ttl {
            guard ttl.isFinite else { return .invalidTTL }
            clampedTTL = min(max(ttl, Self.ttlRange.lowerBound), Self.ttlRange.upperBound)
        } else {
            clampedTTL = Self.defaultTTL
        }

        if let existing = leases[id] {
            // 續約：上限滿時仍可成功（§14.3）。
            let expiresAt = now + clampedTTL
            leases[id] = Lease(
                id: id,
                expiresAt: expiresAt,
                firstHeldAt: existing.firstHeldAt,
                lastHeartbeatAt: now
            )
            tombstones.removeValue(forKey: id)
            return .held(expiresAt: expiresAt, clampedTTL: clampedTTL)
        }

        guard leases.count < Self.maxLeases else { return .tooMany }

        let expiresAt = now + clampedTTL
        leases[id] = Lease(
            id: id,
            expiresAt: expiresAt,
            firstHeldAt: now,
            lastHeartbeatAt: now
        )
        tombstones.removeValue(forKey: id)
        return .held(expiresAt: expiresAt, clampedTTL: clampedTTL)
    }

    /// 不存在回 false，不算錯；不建立跡證、不延長 grace（§14.3）。
    @discardableResult
    public mutating func release(id: String, now: Double) -> Bool {
        guard let existing = leases.removeValue(forKey: id) else {
            return false
        }
        let lastWorkingAt = min(existing.expiresAt, now)
        tombstones[id] = Tombstone(id: id, lastWorkingAt: lastWorkingAt)
        return true
    }

    /// 將已到期的 active 租約轉成 tombstone；移除 grace 已過的 tombstone。
    /// 回傳本次新轉成 tombstone 或被清掉的 id（測試用）。
    @discardableResult
    public mutating func purgeExpired(
        now: Double,
        graceSeconds: Double = defaultGraceSeconds
    ) -> [String] {
        let grace = Self.normalizedGrace(graceSeconds)
        var changed: [String] = []

        for (id, lease) in leases where now >= lease.expiresAt {
            leases.removeValue(forKey: id)
            // 到期時刻作為 lastWorkingAt；已有 tombstone 不延長（不覆寫較早的時刻）。
            if tombstones[id] == nil {
                tombstones[id] = Tombstone(id: id, lastWorkingAt: lease.expiresAt)
            }
            changed.append(id)
        }

        for (id, stone) in tombstones where now >= stone.lastWorkingAt + grace {
            tombstones.removeValue(forKey: id)
            if !changed.contains(id) {
                changed.append(id)
            }
        }

        // 總儲存有界：tombstone 過多時丟最舊的。
        Self.trimTombstones(&tombstones, maxCount: Self.maxLeases)

        return changed.sorted()
    }

    public func active(now: Double) -> [Lease] {
        leases.values
            .filter { now < $0.expiresAt }
            .sorted { $0.id < $1.id }
    }

    /// 仍在 grace 內的 tombstone（供來源層產生 report）。
    public func graceTombstones(
        now: Double,
        graceSeconds: Double = defaultGraceSeconds
    ) -> [Tombstone] {
        let grace = Self.normalizedGrace(graceSeconds)
        return tombstones.values
            .filter { now < $0.lastWorkingAt + grace }
            .sorted { $0.id < $1.id }
    }

    /// 活躍租約＋grace tombstone 的總數（bounded 檢查用）。
    public var storageCount: Int {
        leases.count + tombstones.count
    }

    private static func normalizedGrace(_ graceSeconds: Double) -> Double {
        guard graceSeconds.isFinite, graceSeconds >= 0 else {
            return defaultGraceSeconds
        }
        return graceSeconds
    }

    private static func trimTombstones(_ stones: inout [String: Tombstone], maxCount: Int) {
        guard stones.count > maxCount else { return }
        let sorted = stones.values.sorted { lhs, rhs in
            if lhs.lastWorkingAt != rhs.lastWorkingAt {
                return lhs.lastWorkingAt < rhs.lastWorkingAt
            }
            return lhs.id < rhs.id
        }
        let dropCount = stones.count - maxCount
        for stone in sorted.prefix(dropCount) {
            stones.removeValue(forKey: stone.id)
        }
    }
}
