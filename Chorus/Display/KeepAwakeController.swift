import AppKit
import ChorusCore
import Foundation
import IOKit.pwr_mgt
import Observation

@MainActor
protocol KeepAwakeAsserting {
    func create(type: String, reason: String) -> IOPMAssertionID?
    func isActive(_ id: IOPMAssertionID) -> Bool
    func release(_ id: IOPMAssertionID)
}

struct SystemKeepAwakeAssertions: KeepAwakeAsserting {
    func create(type: String, reason: String) -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id
        )
        guard result == kIOReturnSuccess else {
            ChorusLog.display.error("Keep awake assertion failed: type=\(type), IOReturn=\(result)")
            return nil
        }
        return id
    }

    func isActive(_ id: IOPMAssertionID) -> Bool {
        guard let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any] else {
            return false
        }
        guard let level = properties[kIOPMAssertionLevelKey] as? NSNumber else { return false }
        return level.uint32Value == IOPMAssertionLevel(kIOPMAssertionLevelOn)
    }

    func release(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }
}

/// 螢幕長亮（M9）。公開 API `IOPMAssertionCreateWithName`，無需任何權限。
///
/// 兩檔：
/// - 預設只擋「螢幕待機」（`PreventUserIdleDisplaySleep`）——這是使用者要的：
///   看影片、看儀表板時螢幕別暗掉。
/// - 加擋「系統待機」（`PreventUserIdleSystemSleep`）是額外選項，給長時間
///   下載／編譯的情境。
///
/// Agent 模式（M9-2）是唯一反過來的一檔：只擋系統待機、不擋螢幕待機。
/// agent 跑整夜時要的是機器別睡，螢幕暗掉正好。哪一檔擋什麼由
/// `KeepAwakePlanner.assertionPlan` 決定，不在這裡分支。
///
/// assertion 是 process 綁定的：Chorus 結束時核心自動釋放，
/// 不會有「App 沒了但機器再也不睡」的殘留。
@MainActor
@Observable
final class KeepAwakeController {
    private(set) var mode: KeepAwakeMode = .off
    /// 目前是否真的持有 assertion（模式啟用但條件不成立時為 false，
    /// 例如綁定的螢幕被拔掉、計時器已到期）。
    private(set) var isHolding = false
    /// 條件成立，但 macOS 未接受所有必要的防睡眠請求。
    private(set) var activationFailed = false
    /// 計時模式的剩餘秒數（其餘模式為 nil）。
    /// 存成 property 而非 computed——選單要每秒重繪倒數，得是可觀察的變更。
    private(set) var remainingSeconds: Double?
    /// Agent 活動偵測。只有 Agent 模式會叫它 `start()`，
    /// 其餘模式不必為了沒人看的狀態定期掃目錄。
    let agentActivity: AgentActivityMonitor

    /// 除了螢幕待機，是否連系統待機一起擋。
    var alsoPreventSystemSleep: Bool {
        didSet {
            guard alsoPreventSystemSleep != oldValue else { return }
            settings.keepAwakePreventsSystemSleep = alsoPreventSystemSleep
            reevaluate()
        }
    }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private weak var displayManager: DisplayManager?
    @ObservationIgnored private var startedAt: Double?
    @ObservationIgnored private let assertions: any KeepAwakeAsserting
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private var displayAssertion: IOPMAssertionID?
    @ObservationIgnored private var systemAssertion: IOPMAssertionID?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObservers: [NSObjectProtocol] = []
    /// 只有綁定 App 模式才掛：其餘模式不必為每次 App 啟動／結束醒來。
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []

    init(
        settings: SettingsStore,
        displayManager: DisplayManager,
        agentActivity: AgentActivityMonitor = AgentActivityMonitor(),
        assertions: any KeepAwakeAsserting = SystemKeepAwakeAssertions(),
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.settings = settings
        self.displayManager = displayManager
        self.agentActivity = agentActivity
        self.assertions = assertions
        self.now = now
        alsoPreventSystemSleep = settings.keepAwakePreventsSystemSleep
        agentActivity.onWorkingChanged = { [weak self] in self?.reevaluate() }
    }

    func activate(_ mode: KeepAwakeMode) {
        self.mode = mode
        startedAt = mode == .off ? nil : now()
        updateAppObservers()
        updateWakeObservers()
        updateAgentMonitor()
        reevaluate()
        // 長亮期間持續核對 assertion；建立失敗或失效後仍須重試。
        tickTask?.cancel()
        tickTask = nil
        if mode != .off {
            let interval: Duration
            if case .duration = mode { interval = .seconds(1) } else { interval = .seconds(10) }
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { return }
                    guard !Task.isCancelled, let self, self.mode != .off else { return }
                    self.reevaluate()
                }
            }
        }
    }

    func deactivate() {
        activate(.off)
    }

    /// 顯示器組合變更 → 重新評估「接著某台螢幕時防睡眠」。
    func displaysDidChange() {
        guard case .whileDisplayConnected = mode else { return }
        reevaluate()
    }

    /// App 啟動／結束 → 重新評估「這個 App 執行中才防睡眠」。
    func runningAppsDidChange() {
        guard case .whileAppRunning = mode else { return }
        reevaluate()
    }

    /// App 結束前釋放（核心其實也會自動回收，但明確釋放比較乾淨）。
    func shutdown() {
        deactivate()
    }

    func reevaluate() {
        let currentTime = now()
        remainingSeconds = KeepAwakePlanner.remainingSeconds(mode: mode, startedAt: startedAt, now: currentTime)
        let connected = Set(displayManager?.displays.map(\.uuid) ?? [])
        // 只有綁定 App 模式才查清單：App 事件立即評估，另每十秒檢查恢復。
        var running: Set<String> = []
        if case .whileAppRunning = mode { running = RunningApps.bundleIDs() }
        let shouldHold = KeepAwakePlanner.shouldHoldAssertion(
            mode: mode,
            startedAt: startedAt,
            now: currentTime,
            connectedDisplayUUIDs: connected,
            runningAppBundleIDs: running,
            agentsWorking: agentActivity.isWorking
        )
        let plan = KeepAwakePlanner.assertionPlan(mode: mode, alsoPreventSystemSleep: alsoPreventSystemSleep)
        if shouldHold {
            if plan.preventsDisplaySleep {
                hold(&displayAssertion, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "Chorus 螢幕長亮")
            } else {
                release(&displayAssertion)
            }
            if plan.preventsSystemSleep {
                hold(&systemAssertion, type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: "Chorus 防止系統待機")
            } else {
                release(&systemAssertion)
            }
        } else {
            release(&displayAssertion)
            release(&systemAssertion)
            // 計時到期就把模式收乾淨，UI 才不會停在「開啟中」。
            // 螢幕／App 綁定模式**不收**：螢幕接回來、App 再開時要能自己恢復。
            if case .duration = mode {
                mode = .off
                startedAt = nil
                remainingSeconds = nil
                tickTask?.cancel()
                updateWakeObservers()
            }
        }
        isHolding = shouldHold
            && (!plan.preventsDisplaySleep || displayAssertion != nil)
            && (!plan.preventsSystemSleep || systemAssertion != nil)
        activationFailed = shouldHold && !isHolding
    }

    private func updateWakeObservers() {
        let center = NSWorkspace.shared.notificationCenter
        guard mode != .off else {
            wakeObservers.forEach { center.removeObserver($0) }
            wakeObservers = []
            return
        }
        guard wakeObservers.isEmpty else { return }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reevaluate() }
            })
        }
    }

    /// Agent 模式進出時開／關目錄輪詢。
    private func updateAgentMonitor() {
        if case .whileAgentsWorking = mode {
            agentActivity.start()
        } else {
            agentActivity.stop()
        }
    }

    /// 綁定 App 模式進出時掛上／拆掉 workspace 監聽。
    private func updateAppObservers() {
        var needed = false
        if case .whileAppRunning = mode { needed = true }
        guard needed else { return removeAppObservers() }
        guard appObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            appObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated {
                    AppStateRegistry.keepAwake?.runningAppsDidChange()
                }
            })
        }
    }

    private func removeAppObservers() {
        let center = NSWorkspace.shared.notificationCenter
        appObservers.forEach { center.removeObserver($0) }
        appObservers = []
    }

    private func hold(_ id: inout IOPMAssertionID?, type: String, reason: String) {
        if let existing = id {
            guard !assertions.isActive(existing) else { return }
            assertions.release(existing)
            id = nil
            ChorusLog.display.notice("Keep awake assertion inactive; recreating type=\(type)")
        }
        id = assertions.create(type: type, reason: reason)
    }

    private func release(_ id: inout IOPMAssertionID?) {
        guard let existing = id else { return }
        assertions.release(existing)
        id = nil
    }
}
