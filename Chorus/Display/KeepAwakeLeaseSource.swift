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
    private let uptimeNow: () -> Double

    init(
        graceSeconds: Double = KeepAwakeLeaseTable.defaultGraceSeconds,
        wallNow: @escaping () -> Date = Date.init,
        uptimeNow: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.graceSeconds = graceSeconds
        self.wallNow = wallNow
        self.uptimeNow = uptimeNow
    }

    func start() {
        running = true
        refreshReports(notify: false)
    }

    func stop() {
        running = false
        report = []
    }

    /// Fi A4：模式／automation／token 變更時立即清除，不建立 grace tombstone。
    func clearImmediately() {
        table = KeepAwakeLeaseTable()
        report = []
        // 不觸發 onChange：呼叫端（hub.stop／C08／C09）會自行 recompute 或已停止。
    }

    @discardableResult
    func hold(id: String, ttl: Double?) -> KeepAwakeLeaseTable.HoldResult {
        let result = table.hold(id: id, ttl: ttl, now: uptimeNow())
        refreshReports(notify: true)
        return result
    }

    @discardableResult
    func release(id: String) -> Bool {
        let released = table.release(id: id, now: uptimeNow())
        refreshReports(notify: true)
        return released
    }

    /// 供 C09／C08 組裝 status；會先 purge 過期項。
    func snapshot() -> (
        active: [KeepAwakeLeaseTable.Lease],
        tombstones: [KeepAwakeLeaseTable.Tombstone],
        aggregate: KeepAwakeLeaseTable.AggregateGrace?
    ) {
        let now = uptimeNow()
        _ = table.purgeExpired(now: now, graceSeconds: graceSeconds)
        return (
            table.active(now: now),
            table.graceTombstones(now: now, graceSeconds: graceSeconds),
            table.aggregateGraceContribution(now: now, graceSeconds: graceSeconds)
        )
    }

    /// 測試／tick：依目前 uptime 重算 report。
    func refresh() {
        refreshReports(notify: false)
    }

    // MARK: - Private

    private func refreshReports(notify: Bool) {
        let uptime = uptimeNow()
        _ = table.purgeExpired(now: uptime, graceSeconds: graceSeconds)
        let wall = wallNow()
        let toWall: (Double) -> Date = { up in
            wall.addingTimeInterval(up - uptime)
        }

        var next: [KeepAwakeSourceReport] = []
        for lease in table.active(now: uptime) {
            let remaining = max(0, lease.expiresAt - uptime)
            let minutes = Int((remaining / 60).rounded(.up))
            next.append(
                KeepAwakeSourceReport(
                    id: "lease:\(lease.id)",
                    kind: .lease,
                    displayName: lease.id,
                    detail: "剩 \(max(minutes, 1)) 分",
                    isWorkingNow: true,
                    lastWorkingAt: toWall(lease.lastHeartbeatAt),
                    health: .ok
                )
            )
        }
        for stone in table.graceTombstones(now: uptime, graceSeconds: graceSeconds) {
            next.append(
                KeepAwakeSourceReport(
                    id: "lease:\(stone.id)",
                    kind: .lease,
                    displayName: stone.id,
                    detail: nil,
                    isWorkingNow: false,
                    lastWorkingAt: toWall(stone.lastWorkingAt),
                    health: .ok
                )
            )
        }
        if let aggregate = table.aggregateGraceContribution(now: uptime, graceSeconds: graceSeconds) {
            next.append(
                KeepAwakeSourceReport(
                    id: "lease:aggregate-grace",
                    kind: .lease,
                    displayName: "租約寬限",
                    detail: "摺疊 \(aggregate.foldedCount) 筆",
                    isWorkingNow: false,
                    lastWorkingAt: toWall(aggregate.lastWorkingAt),
                    health: .ok
                )
            )
        }

        report = next
        if notify { onChange?() }
    }
}
