import ChorusCore
import Foundation
import Observation

/// 單一工作來源協定（spec §4.7）。與 hub 同檔。
@MainActor
protocol KeepAwakeSource: AnyObject {
    var report: [KeepAwakeSourceReport] { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}

/// Hub／設定頁共用的來源開關（spec §8.1）。
struct KeepAwakeSourceSettings: Equatable, Sendable {
    var orcaEnabled: Bool = true
    var orcaCountsPermission: Bool = true
    var orcaCLIPath: String? = nil
    var desktopAgentsEnabled: Bool = true
    var grokBotEnabled: Bool = false

    static let `default` = KeepAwakeSourceSettings()
}

/// §14.3：未來 mtime 在第一次觀察時 clamp；同一份未變 raw 不可每 tick 重送「剛剛」。
struct KeepAwakeMtimeClampCache: Sendable {
    private var entries: [String: (raw: Date, clamped: Date)] = [:]
    /// 有界：live pruning 與容量淘汰均保留不延長 grace 的摘要。
    private let maxEntries: Int
    // Compact conservative tombstone: an evicted unchanged raw can never normalize later.
    // This may suppress new evidence below the ceiling; it cannot extend grace.
    private var retiredRawCeiling: Date?
    private var retiredClampFloor: Date?

    init(maxEntries: Int = 256) {
        self.maxEntries = max(1, maxEntries)
    }

    mutating func stabilize(id: String, raw: Date, now: Date) -> Date {
        if let existing = entries[id], existing.raw == raw {
            return existing.clamped
        }
        var clamped = KeepAwakeBusyAggregator.normalizedLastWorkingAt(raw, now: now)
        if let ceiling = retiredRawCeiling, let floor = retiredClampFloor, raw <= ceiling {
            clamped = min(clamped, floor)
        }
        entries[id] = (raw, clamped)
        if entries.count > maxEntries {
            // Retire the normalization before eviction, including live entries.
            let overflow = entries.count - maxEntries
            for key in Array(entries.keys.prefix(overflow)) {
                if let entry = entries.removeValue(forKey: key) { retire(entry) }
            }
        }
        return clamped
    }

    mutating func retainIds(_ ids: Set<String>) {
        for key in Array(entries.keys) where !ids.contains(key) {
            if let entry = entries.removeValue(forKey: key) { retire(entry) }
        }
    }

    private mutating func retire(_ entry: (raw: Date, clamped: Date)) {
        // Ordinary past evidence normalizes to itself and needs no tombstone.
        guard entry.clamped < entry.raw else { return }
        retiredRawCeiling = max(retiredRawCeiling ?? entry.raw, entry.raw)
        retiredClampFloor = min(retiredClampFloor ?? entry.clamped, entry.clamped)
    }

    mutating func removeAll() {
        entries.removeAll()
        retiredRawCeiling = nil
        retiredClampFloor = nil
    }
}

/// 多來源 OR ＋ 30 秒 tick（spec §4.7）。
@MainActor
@Observable
final class KeepAwakeSourceHub {
    private(set) var reports: [KeepAwakeSourceReport] = []
    private(set) var busy: KeepAwakeBusyState = .init(isBusy: false, contributing: [], releaseAt: nil)
    var isBusy: Bool { busy.isBusy }

    @ObservationIgnored var onBusyChanged: (() -> Void)?

    let agentActivity: AgentActivityMonitor
    let orca: OrcaActivitySource
    let desktop: DesktopAgentSource
    let leases: KeepAwakeLeaseSource
    let appPresence: AppPresenceSource

    @ObservationIgnored private var settings: KeepAwakeSourceSettings = .default
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private let graceSeconds: Double
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private let now: () -> Date

    init(
        agentActivity: AgentActivityMonitor = AgentActivityMonitor(),
        orca: OrcaActivitySource = OrcaActivitySource(),
        desktop: DesktopAgentSource = DesktopAgentSource(),
        leases: KeepAwakeLeaseSource = KeepAwakeLeaseSource(),
        appPresence: AppPresenceSource = AppPresenceSource(),
        graceSeconds: Double = KeepAwakeBusyAggregator.defaultGraceSeconds,
        tickInterval: Duration = .seconds(30),
        now: @escaping () -> Date = Date.init
    ) {
        self.agentActivity = agentActivity
        self.orca = orca
        self.desktop = desktop
        self.leases = leases
        self.appPresence = appPresence
        self.graceSeconds = graceSeconds
        self.tickInterval = tickInterval
        self.now = now

        wireSources()
    }

    func start() {
        guard !running else { return }
        running = true
        syncOrcaFallbackCapability()
        applySourceLifecycle()
        recompute()
        tickTask?.cancel()
        tickTask = Task { [weak self, tickInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    /// 離開 Agent 模式：全部停止並清空，**不**回呼 `onBusyChanged`。
    func stop() {
        running = false
        tickTask?.cancel()
        tickTask = nil
        agentActivity.stop()
        orca.stop()
        desktop.stop()
        leases.stop()
        appPresence.stop()
        // Fi A4：離開 Agent 立即清租約、不延長 grace。leases 已 stop → clear 不通知。
        leases.clearImmediately()
        agentActivity.clearMtimeClamp()
        desktop.clearMtimeClamp()
        reports = []
        busy = .init(isBusy: false, contributing: [], releaseAt: nil)
    }

    func configure(_ settings: KeepAwakeSourceSettings) {
        let previous = self.settings
        self.settings = settings
        orca.configure(
            enabled: settings.orcaEnabled,
            countPermissionAsWorking: settings.orcaCountsPermission,
            cliPathOverride: settings.orcaCLIPath
        )
        desktop.configure(enabled: settings.desktopAgentsEnabled)
        appPresence.configure(enabled: settings.grokBotEnabled)
        syncOrcaFallbackCapability()

        guard running else { return }
        applySourceLifecycle()
        if previous.grokBotEnabled, !settings.grokBotEnabled {
            appPresence.clearEvidence()
        }
        if previous.orcaEnabled, !settings.orcaEnabled {
            orca.clearEvidence()
        }
        if previous.desktopAgentsEnabled, !settings.desktopAgentsEnabled {
            desktop.clearEvidence()
        }
        recompute()
    }

    /// 30 秒 tick：刷新時間敏感來源後再聚合（C7-1／C7-5；不經來源 onChange 遞迴）。
    func tick() {
        guard running else { return }
        leases.refresh()
        appPresence.refresh(notify: false)
        orca.refreshAbsenceGraceIfNeeded()
        recompute()
    }

    func recompute() {
        guard running else { return }
        let instant = now()
        var next: [KeepAwakeSourceReport] = []

        if let agents = agentActivity.sourceReport(now: instant) {
            next.append(agents)
        }
        next.append(contentsOf: orca.report)
        next.append(contentsOf: desktop.report)
        next.append(contentsOf: leases.report)
        next.append(contentsOf: appPresence.report)

        let previousReports = reports
        let previousBusy = busy
        reports = next
        busy = KeepAwakeBusyAggregator.evaluate(next, now: instant, graceSeconds: graceSeconds)
        // §14.3／C7-6：busy 布林不變但來源／細節／releaseAt 變了也要通知。
        if previousBusy != busy || previousReports != reports {
            onBusyChanged?()
        }
    }

    // MARK: - Private

    private func wireSources() {
        let notify: () -> Void = { [weak self] in self?.recompute() }
        agentActivity.onWorkingChanged = notify
        orca.onChange = notify
        desktop.onChange = notify
        leases.onChange = notify
        appPresence.onChange = notify
    }

    private func applySourceLifecycle() {
        agentActivity.start()
        if settings.orcaEnabled { orca.start() } else { orca.stop() }
        if settings.desktopAgentsEnabled { desktop.start() } else { desktop.stop() }
        leases.start()
        if settings.grokBotEnabled { appPresence.start() } else { appPresence.stop() }
    }

    /// C7-7：TTY／行程偵測開關決定是否可宣稱「改用行程偵測」（M-6 未驗證 → unverified）。
    private func syncOrcaFallbackCapability() {
        orca.fallbackCapability = agentActivity.isProcessDetectionEnabled
            ? .unverified
            : .unavailable
    }
}
