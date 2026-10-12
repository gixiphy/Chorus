import ChorusCore
import Foundation

/// 心跳租約來源：包裝 `KeepAwakeLeaseTable`（spec §4.5）。
@MainActor
final class KeepAwakeLeaseSource: KeepAwakeSource {
    private(set) var report: [KeepAwakeSourceReport] = []
    var onChange: (() -> Void)?

    private var table = KeepAwakeLeaseTable()
    private var running = false
    private let graceSeconds: Double
    private let wallNow: () -> Date
    /// Optional continuous sample; `nil` means the primary clock failed this read.
    private let continuousNow: () -> Double?
    /// Last successful sample is retained for wire display only, never lease admission.
    private var lastGoodContinuous: Double?
    /// Stable wall conversion for an unchanged heartbeat uptime stamp (V1-2).
    private var wallAnchors: [String: (uptimeStamp: Double, wall: Date)] = [:]

    init(
        graceSeconds: Double = KeepAwakeLeaseTable.defaultGraceSeconds,
        wallNow: @escaping () -> Date = Date.init,
        /// Cross-sleep continuous clock (V1-7). Injected Double clocks are treated as always-available.
        uptimeNow: @escaping () -> Double
    ) {
        self.graceSeconds = graceSeconds
        self.wallNow = wallNow
        self.continuousNow = { uptimeNow() }
    }

    /// Production default: `LidMonotonicTime` — never fall back to `systemUptime` (V1-7).
    init(
        graceSeconds: Double = KeepAwakeLeaseTable.defaultGraceSeconds,
        wallNow: @escaping () -> Date = Date.init
    ) {
        self.graceSeconds = graceSeconds
        self.wallNow = wallNow
        self.continuousNow = { LidMonotonicTime.seconds() }
    }

    /// Explicit optional continuous clock (tests for clock-failure freeze).
    init(
        graceSeconds: Double = KeepAwakeLeaseTable.defaultGraceSeconds,
        wallNow: @escaping () -> Date = Date.init,
        continuousNow: @escaping () -> Double?
    ) {
        self.graceSeconds = graceSeconds
        self.wallNow = wallNow
        self.continuousNow = continuousNow
    }

    /// Shared continuous clock for hold/status wire remaining time (V1-7／V1-11).
    func currentUptime() -> Double {
        guard let sample = sampleContinuous() else {
            clearImmediately()
            return lastGoodContinuous ?? 0
        }
        return sample
    }

    /// Failed, invalid or backwards samples cannot keep work alive or change epochs.
    private func sampleContinuous() -> Double? {
        if let sample = continuousNow(), sample.isFinite, sample >= 0,
           sample >= (lastGoodContinuous ?? 0) {
            lastGoodContinuous = sample
            return sample
        }
        return nil
    }

    func start() {
        // V1-2: already-running start is a no-op (no fresh wall sample / notify).
        guard !running else { return }
        running = true
        refreshReports(notify: false)
    }

    func stop() {
        running = false
        report = []
        wallAnchors = [:]
    }

    /// Fi A4：模式／automation／token 變更時立即清除，不建立 grace tombstone。
    /// 來源仍在跑時通知 hub 立刻 recompute（C7-9）；`hub.stop` 先 `stop()` 再清 → 靜默。
    func clearImmediately() {
        table = KeepAwakeLeaseTable()
        report = []
        wallAnchors = [:]
        if running {
            onChange?()
        }
    }

    @discardableResult
    func hold(id: String, ttl: Double?) -> KeepAwakeLeaseTable.HoldResult {
        guard let now = sampleContinuous() else {
            clearImmediately()
            return .clockUnavailable
        }
        // Table purges at the same `now` before capacity (V1-9).
        let result = table.hold(id: id, ttl: ttl, now: now)
        refreshReports(notify: true)
        return result
    }

    @discardableResult
    func release(id: String) -> Bool {
        guard let now = sampleContinuous() else {
            clearImmediately()
            return false
        }
        let released = table.release(id: id, now: now)
        refreshReports(notify: true)
        return released
    }

    /// 供 C09／C08 組裝 status；會先 purge 過期項並同步 report。
    func snapshot() -> (
        active: [KeepAwakeLeaseTable.Lease],
        tombstones: [KeepAwakeLeaseTable.Tombstone],
        aggregate: KeepAwakeLeaseTable.AggregateGrace?
    ) {
        guard let now = sampleContinuous() else {
            clearImmediately()
            return ([], [], nil)
        }
        _ = table.purgeExpired(now: now, graceSeconds: graceSeconds)
        refreshReports(notify: false)
        return (
            table.active(now: now),
            table.graceTombstones(now: now, graceSeconds: graceSeconds),
            table.aggregateGraceContribution(now: now, graceSeconds: graceSeconds)
        )
    }

    /// 測試／hub tick：依目前 uptime 重算 report（不通知，由呼叫端 recompute）。
    func refresh() {
        refreshReports(notify: false)
    }

    // MARK: - Private

    private func refreshReports(notify: Bool) {
        guard let uptime = sampleContinuous() else {
            let previous = report
            table = KeepAwakeLeaseTable()
            report = []
            wallAnchors = [:]
            if notify, !previous.isEmpty { onChange?() }
            return
        }
        _ = table.purgeExpired(now: uptime, graceSeconds: graceSeconds)

        var next: [KeepAwakeSourceReport] = []
        var liveIDs: Set<String> = []
        for lease in table.active(now: uptime) {
            liveIDs.insert(lease.id)
            let remaining = max(0, lease.expiresAt - uptime)
            let minutes = Int((remaining / 60).rounded(.up))
            next.append(
                KeepAwakeSourceReport(
                    id: "lease:\(lease.id)",
                    kind: .lease,
                    displayName: lease.id,
                    detail: "剩 \(max(minutes, 1)) 分",
                    isWorkingNow: true,
                    lastWorkingAt: stableWall(id: lease.id, uptimeStamp: lease.lastHeartbeatAt, sampleUptime: uptime),
                    health: .ok
                )
            )
        }
        for stone in table.graceTombstones(now: uptime, graceSeconds: graceSeconds) {
            liveIDs.insert(stone.id)
            next.append(
                KeepAwakeSourceReport(
                    id: "lease:\(stone.id)",
                    kind: .lease,
                    displayName: stone.id,
                    detail: nil,
                    isWorkingNow: false,
                    lastWorkingAt: stableWall(id: stone.id, uptimeStamp: stone.lastWorkingAt, sampleUptime: uptime),
                    health: .ok
                )
            )
        }
        if let aggregate = table.aggregateGraceContribution(now: uptime, graceSeconds: graceSeconds) {
            let aggID = "aggregate-grace"
            liveIDs.insert(aggID)
            next.append(
                KeepAwakeSourceReport(
                    id: "lease:aggregate-grace",
                    kind: .lease,
                    displayName: "租約寬限",
                    detail: "摺疊 \(aggregate.foldedCount) 筆",
                    isWorkingNow: false,
                    lastWorkingAt: stableWall(id: aggID, uptimeStamp: aggregate.lastWorkingAt, sampleUptime: uptime),
                    health: .ok
                )
            )
        }
        wallAnchors = wallAnchors.filter { liveIDs.contains($0.key) }

        let previous = report
        report = next
        // Preserve real detail/source-change notifications; skip no-op churn (V1-2).
        if notify, previous != next { onChange?() }
    }

    /// Wall display anchor is stable until the underlying continuous stamp changes.
    private func stableWall(id: String, uptimeStamp: Double, sampleUptime: Double) -> Date {
        if let cached = wallAnchors[id], cached.uptimeStamp == uptimeStamp {
            return cached.wall
        }
        let wall = wallNow().addingTimeInterval(uptimeStamp - sampleUptime)
        wallAnchors[id] = (uptimeStamp, wall)
        return wall
    }
}
