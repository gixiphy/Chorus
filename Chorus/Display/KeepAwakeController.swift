import AppKit
import ChorusCore
import Foundation
import IOKit.pwr_mgt
import Observation

/// 螢幕長亮（M9）。公開 API `IOPMAssertionCreateWithName`，無需任何權限。
///
/// 兩檔：
/// - 預設只擋「螢幕待機」（`PreventUserIdleDisplaySleep`）——這是使用者要的：
///   看影片、看儀表板時螢幕別暗掉。
/// - 加擋「系統待機」（`PreventUserIdleSystemSleep`）是額外選項，給長時間
///   下載／編譯的情境。
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
    /// 計時模式的剩餘秒數（其餘模式為 nil）。
    /// 存成 property 而非 computed——選單要每秒重繪倒數，得是可觀察的變更。
    private(set) var remainingSeconds: Double?

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
    @ObservationIgnored private var displayAssertion: IOPMAssertionID = 0
    @ObservationIgnored private var systemAssertion: IOPMAssertionID = 0
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// 只有綁定 App 模式才掛：其餘模式不必為每次 App 啟動／結束醒來。
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []

    init(settings: SettingsStore, displayManager: DisplayManager) {
        self.settings = settings
        self.displayManager = displayManager
        alsoPreventSystemSleep = settings.keepAwakePreventsSystemSleep
    }

    func activate(_ mode: KeepAwakeMode) {
        self.mode = mode
        startedAt = mode == .off ? nil : Self.now
        updateAppObservers()
        reevaluate()
        // 計時模式需要輪詢到期；其餘模式靠事件驅動即可
        tickTask?.cancel()
        tickTask = nil
        if case .duration = mode {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard let self else { return }
                    self.reevaluate()
                    if !self.isHolding { return }
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
        tickTask?.cancel()
        removeAppObservers()
        release(&displayAssertion)
        release(&systemAssertion)
        isHolding = false
    }

    private func reevaluate() {
        remainingSeconds = KeepAwakePlanner.remainingSeconds(mode: mode, startedAt: startedAt, now: Self.now)
        let connected = Set(displayManager?.displays.map(\.uuid) ?? [])
        // 執行中 App 清單每次現查——只有綁定 App 模式會走到，
        // 而那個模式是事件驅動的，不會每秒問一次。
        var running: Set<String> = []
        if case .whileAppRunning = mode { running = RunningApps.bundleIDs() }
        let shouldHold = KeepAwakePlanner.shouldHoldAssertion(
            mode: mode,
            startedAt: startedAt,
            now: Self.now,
            connectedDisplayUUIDs: connected,
            runningAppBundleIDs: running
        )
        if shouldHold {
            hold(&displayAssertion, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "Chorus 螢幕長亮")
            if alsoPreventSystemSleep {
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
            }
        }
        isHolding = shouldHold
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

    private func hold(_ id: inout IOPMAssertionID, type: String, reason: String) {
        guard id == 0 else { return }
        var created: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &created
        )
        guard result == kIOReturnSuccess else { return }
        id = created
    }

    private func release(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }

    private static var now: Double { ProcessInfo.processInfo.systemUptime }
}
