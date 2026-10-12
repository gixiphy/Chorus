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

    mutating func stabilize(id: String, raw: Date, now: Date) -> Date {
        if let existing = entries[id], existing.raw == raw {
            return existing.clamped
        }
        let clamped = KeepAwakeBusyAggregator.normalizedLastWorkingAt(raw, now: now)
        entries[id] = (raw, clamped)
        return clamped
    }

    mutating func removeAll() {
        entries.removeAll()
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
        applySourceLifecycle()
        recompute()
        tickTask?.cancel()
        tickTask = Task { [weak self, tickInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tickInterval)
                guard let self, !Task.isCancelled else { return }
                self.recompute()
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
        // Fi A4：離開 Agent 立即清租約、不延長 grace。
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

        reports = next
        let previousBusy = busy.isBusy
        busy = KeepAwakeBusyAggregator.evaluate(next, now: instant, graceSeconds: graceSeconds)
        if previousBusy != busy.isBusy {
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
}
