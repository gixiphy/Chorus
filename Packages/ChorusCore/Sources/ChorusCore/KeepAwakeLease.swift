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
        /// Clamped TTL from the most recent hold/renew (wire status accuracy, V1-11).
        public var ttl: Double

        public init(
            id: String,
            expiresAt: Double,
            firstHeldAt: Double,
            lastHeartbeatAt: Double,
            ttl: Double = KeepAwakeLeaseTable.defaultTTL
        ) {
            self.id = id
            self.expiresAt = expiresAt
            self.firstHeldAt = firstHeldAt
            self.lastHeartbeatAt = lastHeartbeatAt
            self.ttl = ttl
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

    /// 個別 tombstone 槽滿時，多餘的已接受 grace 跡證摺疊於此（W0-7）。
    /// 保留 `lastWorkingAt` 最大值，使 busy／releaseAt 證據不因有界儲存而提早消失。
    public struct AggregateGrace: Sendable, Equatable {
        public var foldedCount: Int
        public var lastWorkingAt: Double

        public init(foldedCount: Int, lastWorkingAt: Double) {
            self.foldedCount = foldedCount
            self.lastWorkingAt = lastWorkingAt
        }
    }

    public enum HoldResult: Equatable, Sendable {
        case held(expiresAt: Double, clampedTTL: Double)
        case invalidID
        case invalidTTL
        case tooMany
        /// The App source cannot safely admit a lease without a continuous timestamp.
        case clockUnavailable
    }

    public private(set) var leases: [String: Lease] = [:]
    public private(set) var tombstones: [String: Tombstone] = [:]
    /// 超出個別 tombstone 上限後的有界彙總；nil 表示沒有摺疊證據。
    public private(set) var aggregateGrace: AggregateGrace?

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

        // V1-9: purge at the same sampled `now` before capacity so expired slots free up.
        // Retains grace tombstones via purgeExpired.
        _ = purgeExpired(now: now, graceSeconds: Self.defaultGraceSeconds)

        if let existing = leases[id] {
            // 續約：上限滿時仍可成功（§14.3）。
            let expiresAt = now + clampedTTL
            leases[id] = Lease(
                id: id,
                expiresAt: expiresAt,
                firstHeldAt: existing.firstHeldAt,
                lastHeartbeatAt: now,
                ttl: clampedTTL
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
            lastHeartbeatAt: now,
            ttl: clampedTTL
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
        admitTombstone(id: id, lastWorkingAt: lastWorkingAt)
        return true
    }

    /// 將已到期的 active 租約轉成 tombstone；移除 grace 已過的 tombstone。
    /// 回傳本次新轉成 tombstone 或被清掉的 id（測試用）。
    ///
    /// 不會提早刪掉仍在 grace 的個別報告（§14.3／W0-7）；超出容量時摺入 `aggregateGrace`。
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
                admitTombstone(id: id, lastWorkingAt: lease.expiresAt)
            }
            changed.append(id)
        }

        for (id, stone) in tombstones where now >= stone.lastWorkingAt + grace {
            tombstones.removeValue(forKey: id)
            if !changed.contains(id) {
                changed.append(id)
            }
        }

        if let aggregate = aggregateGrace, now >= aggregate.lastWorkingAt + grace {
            aggregateGrace = nil
        }

        return changed.sorted()
    }

    public func active(now: Double) -> [Lease] {
        leases.values
            .filter { now < $0.expiresAt }
            .sorted { $0.id < $1.id }
    }

    /// 仍在 grace 內的個別 tombstone（供來源層產生 per-id report）。
    public func graceTombstones(
        now: Double,
        graceSeconds: Double = defaultGraceSeconds
    ) -> [Tombstone] {
        let grace = Self.normalizedGrace(graceSeconds)
        return tombstones.values
            .filter { now < $0.lastWorkingAt + grace }
            .sorted { $0.id < $1.id }
    }

    /// 彙總 grace 是否仍有效（有界摺疊後的最新證據）。
    public func aggregateGraceContribution(
        now: Double,
        graceSeconds: Double = defaultGraceSeconds
    ) -> AggregateGrace? {
        let grace = Self.normalizedGrace(graceSeconds)
        guard let aggregate = aggregateGrace, now < aggregate.lastWorkingAt + grace else {
            return nil
        }
        return aggregate
    }

    /// 活躍租約＋個別 tombstone＋（若有）彙總槽。恆 ≤ `maxLeases * 2 + 1`。
    public var storageCount: Int {
        leases.count + tombstones.count + (aggregateGrace == nil ? 0 : 1)
    }

    /// 所有仍在 grace 的 lastWorkingAt（個別＋彙總），供 busy 聚合。
    public func graceEvidenceTimes(
        now: Double,
        graceSeconds: Double = defaultGraceSeconds
    ) -> [Double] {
        let grace = Self.normalizedGrace(graceSeconds)
        var times = tombstones.values
            .map(\.lastWorkingAt)
            .filter { now < $0 + grace }
        if let aggregate = aggregateGrace, now < aggregate.lastWorkingAt + grace {
            times.append(aggregate.lastWorkingAt)
        }
        return times
    }

    private mutating func admitTombstone(id: String, lastWorkingAt: Double) {
        if tombstones[id] != nil {
            // 不延長既有 grace
            return
        }
        if tombstones.count < Self.maxLeases {
            tombstones[id] = Tombstone(id: id, lastWorkingAt: lastWorkingAt)
            return
        }
        // 個別槽滿：摺入彙總，保留最新證據，不丟棄已接受的 grace（W0-7）。
        if let existing = aggregateGrace {
            aggregateGrace = AggregateGrace(
                foldedCount: existing.foldedCount + 1,
                lastWorkingAt: max(existing.lastWorkingAt, lastWorkingAt)
            )
        } else {
            aggregateGrace = AggregateGrace(foldedCount: 1, lastWorkingAt: lastWorkingAt)
        }
    }

    private static func normalizedGrace(_ graceSeconds: Double) -> Double {
        guard graceSeconds.isFinite, graceSeconds >= 0 else {
            return defaultGraceSeconds
        }
        return graceSeconds
    }
}
