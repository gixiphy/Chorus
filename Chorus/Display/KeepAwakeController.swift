import AppKit
import ChorusCore
import Foundation
import IOKit.pwr_mgt
import Observation
import Synchronization

@MainActor
protocol KeepAwakeAsserting {
    func create(type: String, reason: String) -> IOPMAssertionID?
    func isActive(_ id: IOPMAssertionID) -> Bool
    func release(_ id: IOPMAssertionID)
}

/// `create` 持續失敗時的 error log 節流（review #7／P0：避免日誌變負載）。
enum KeepAwakeCreateErrorThrottle {
    private struct State {
        var lastLogAt: [String: Double] = [:]
        var suppressedSinceLog: [String: Int] = [:]
    }

    private static let state = Mutex(State())
    private static let defaultInterval: Double = 60

    static func resetForTesting() {
        state.withLock { $0 = State() }
    }

    /// - Returns: `shouldLog` 為 true 時應寫一行 error；`suppressed` 為本次一併彙總的略過數。
    static func noteFailure(type: String, now: Double, interval: Double = defaultInterval) -> (
        shouldLog: Bool, suppressed: Int
    ) {
        state.withLock { state in
            if let last = state.lastLogAt[type], now - last < interval {
                state.suppressedSinceLog[type, default: 0] += 1
                return (false, state.suppressedSinceLog[type] ?? 0)
            }
            let suppressed = state.suppressedSinceLog[type] ?? 0
            state.lastLogAt[type] = now
            state.suppressedSinceLog[type] = 0
            return (true, suppressed)
        }
    }
}

struct SystemKeepAwakeAssertions: KeepAwakeAsserting {
    func create(type: String, reason: String) -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id
        )
        guard result == kIOReturnSuccess else {
            let label = type == kIOPMAssertionTypePreventUserIdleDisplaySleep ? "display"
                : type == kIOPMAssertionTypePreventUserIdleSystemSleep ? "system" : "other"
            let note = KeepAwakeCreateErrorThrottle.noteFailure(
                type: label, now: ProcessInfo.processInfo.systemUptime
            )
            if note.shouldLog {
                if note.suppressed > 0 {
                    ChorusLog.display.error(
                        "Keep awake assertion failed: type=\(type), IOReturn=\(result), suppressed=\(note.suppressed)"
                    )
                } else {
                    ChorusLog.display.error(
                        "Keep awake assertion failed: type=\(type), IOReturn=\(result)"
                    )
                }
            }
            return nil
        }
        return id
    }

    func isActive(_ id: IOPMAssertionID) -> Bool {
        guard let properties = IOPMAssertionCopyProperties(id)?.takeRetainedValue() as? [String: Any] else {
            return false
        }
        let level = (properties[kIOPMAssertionLevelKey] as? NSNumber)?.uint32Value
        return level == UInt32(kIOPMAssertionLevelOn)
    }

    func release(_ id: IOPMAssertionID) {
        IOPMAssertionRelease(id)
    }
}

enum KeepAwakeReevaluationReason: String, Sendable {
    case hub
    case lid
    case load
    case power
    case tick
    case wake
    case session
    case direct
    case settings
    case displays
    case apps
    case hold
    case pending
    case sleep
}

enum KeepAwakeReevaluationUrgency: Sendable {
    /// 250ms trailing coalesce（一般 callback）。
    case normal
    /// 同步立即執行（公開 `reevaluate()`、tick、wake）。
    case immediate
    /// 同步且不可延後（power floor trip、模式關閉後釋放）。
    case safety
}

private enum AssertionVerifyTrigger: String {
    case power
    case session
    case wake
}

struct KeepAwakeReevaluationStats: Equatable, Sendable {
    var triggered = 0
    var coalesced = 0
    var executed = 0
    var skippedUnchanged = 0
    var triggeredByReason: [String: Int] = [:]
}

/// 螢幕長亮（M9）。公開 API `IOPMAssertionCreateWithName`，無需任何權限。
///
/// 兩檔：
/// - 預設只擋「螢幕待機」（`PreventUserIdleDisplaySleep`）——這是使用者要的：
///   看影片、看儀表板時螢幕別暗掉。
/// - 加擋「系統待機」（`PreventUserIdleSystemSleep`）是額外選項，給長時間
///   下載／編譯的情境。
///
/// Agent 模式（M9-2）固定同時擋螢幕與系統待機，避免工作被待機中斷。
/// 哪一檔擋什麼由
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
    /// 電量／溫度底線目前是否要求暫停（模式保留、assertion 放掉）。
    private(set) var pauseReason: PowerFloorState = .ok
    /// 溫度 `.serious`：不暫停，選單顯示警告。
    private(set) var thermalWarning = false
    /// 計時模式的剩餘秒數（其餘模式為 nil）。
    /// 存成 property 而非 computed——選單要每秒重繪倒數，得是可觀察的變更。
    private(set) var remainingSeconds: Double?
    /// 多來源 OR hub（spec §4.7／§7.1）。合併模式才 `start()`。
    let sourceHub: KeepAwakeSourceHub
    /// 闔蓋防睡控制器（spec §5.5）。
    let lidGuard: LidSleepGuardController
    /// 相容別名：UI／既有綁定仍讀 `agentActivity`。
    var agentActivity: AgentActivityMonitor { sourceHub.agentActivity }
    /// 整機負載偵測。合併模式才 `start()`。
    let systemLoad: SystemLoadMonitor
    /// 電量／溫度監聽。只有 `mode != .off` 時啟動。
    let powerSource: any PowerSourceObserving
    /// 閒置熄屏。合併模式持有中會驅動（不分觸發來源）。
    let idleBlanker: AgentIdleBlanker

    /// 除了螢幕待機，是否連系統待機一起擋。
    var alsoPreventSystemSleep: Bool {
        didSet {
            guard alsoPreventSystemSleep != oldValue else { return }
            settings.keepAwakePreventsSystemSleep = alsoPreventSystemSleep
            requestReevaluation(reason: .settings, urgency: .immediate)
        }
    }

    /// 用電池時的電量底線；溫度臨界不受此設定影響。
    var batteryFloor: KeepAwakeBatteryFloor {
        didSet {
            guard batteryFloor != oldValue else { return }
            settings.keepAwakeBatteryFloor = batteryFloor
            requestReevaluation(reason: .settings, urgency: .immediate)
        }
    }

    /// Agent 模式是否也看行程樹的 CPU 活動（第二層偵測）。
    var agentProcessDetectionEnabled: Bool {
        didSet {
            guard agentProcessDetectionEnabled != oldValue else { return }
            settings.keepAwakeProcessDetection = agentProcessDetectionEnabled
            agentActivity.configureProcessDetection(
                enabled: agentProcessDetectionEnabled, customProcessNames: agentCustomProcessNames
            )
        }
    }

    /// 使用者自己補的 agent 行程名（註冊表以外的 CLI）。
    var agentCustomProcessNames: [String] {
        didSet {
            guard agentCustomProcessNames != oldValue else { return }
            settings.keepAwakeCustomProcessNames = agentCustomProcessNames
            agentActivity.configureProcessDetection(
                enabled: agentProcessDetectionEnabled, customProcessNames: agentCustomProcessNames
            )
        }
    }

    /// Agent 模式閒置熄屏（預設關閉）。
    var agentIdleBlankEnabled: Bool {
        didSet {
            guard agentIdleBlankEnabled != oldValue else { return }
            settings.keepAwakeAgentIdleBlankEnabled = agentIdleBlankEnabled
            updateIdleBlanker()
        }
    }

    /// 閒置多久後熄屏。
    var agentIdleBlankMinutes: KeepAwakeAgentIdleMinutes {
        didSet {
            guard agentIdleBlankMinutes != oldValue else { return }
            settings.keepAwakeAgentIdleMinutes = agentIdleBlankMinutes
            updateIdleBlanker()
        }
    }

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private weak var displayManager: DisplayManager?
    @ObservationIgnored private(set) var startedAt: Double?
    @ObservationIgnored private let assertions: any KeepAwakeAsserting
    @ObservationIgnored private let notifier: any KeepAwakeNotifying
    @ObservationIgnored private let now: () -> Double
    @ObservationIgnored private let workspaceNotifications: NotificationCenter
    @ObservationIgnored private let log: ChorusLog
    /// 穩態持有不查 powerd；喚醒／session／此間隔才呼叫 `isActive`。
    @ObservationIgnored private let assertionVerifyInterval: Double
    @ObservationIgnored private var displayAssertion: IOPMAssertionID?
    @ObservationIgnored private var systemAssertion: IOPMAssertionID?
    /// 喚醒或電源相關通知要求下一輪 `hold` 驗證本程序 assertion。
    @ObservationIgnored private var pendingAssertionVerifyTrigger: AssertionVerifyTrigger?
    /// 本輪是否強制驗證所有既有 ID（喚醒／session／電源）；與 per-type 保底分開。
    @ObservationIgnored private var forceVerifyThisPass = false
    /// 本輪驗證的觸發來源，寫進 released／recreated 事件。
    @ObservationIgnored private var verifyTrigger = "heartbeat"
    /// display／system 各自的上次 `isActive` 或成功建立時間；新建不得延後另一類保底。
    @ObservationIgnored private var lastDisplayAssertionVerifyAt: Double?
    @ObservationIgnored private var lastSystemAssertionVerifyAt: Double?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    /// 只有綁定 App 模式才掛：其餘模式不必為每次 App 啟動／結束醒來。
    @ObservationIgnored private var appObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var shutDown = false
    /// V1-2: coalesce sync hub→reevaluate→configure cycles.
    @ObservationIgnored private var reevaluating = false
    @ObservationIgnored private var pendingReevaluate = false
    /// 同一次觸發不重複發通知；恢復後清掉。
    @ObservationIgnored private var didNotifyCurrentTrip = false
    /// P2：一般 callback 的 trailing coalesce 間隔。
    @ObservationIgnored private let reevaluationCoalesce: Duration
    @ObservationIgnored private var coalesceTask: Task<Void, Never>?
    @ObservationIgnored private var coalesceDeadline: ContinuousClock.Instant?
    @ObservationIgnored private var coalesceGeneration: UInt64 = 0
    @ObservationIgnored private var lastInputSnapshot: ReevaluationInputSnapshot?
    @ObservationIgnored private var lastThrottleSummaryAt: Double?
    @ObservationIgnored private(set) var reevaluationStats = KeepAwakeReevaluationStats()
    /// 本輪是否強制略過「輸入未變」捷徑（喚醒／safety／verify）。
    @ObservationIgnored private var forceInputChangeThisPass = false

    init(
        settings: SettingsStore,
        displayManager: DisplayManager,
        agentActivity: AgentActivityMonitor = AgentActivityMonitor(),
        sourceHub: KeepAwakeSourceHub? = nil,
        lidGuard: LidSleepGuardController? = nil,
        systemLoad: SystemLoadMonitor = SystemLoadMonitor(),
        powerSource: any PowerSourceObserving = PowerSourceMonitor(),
        idleBlanker: AgentIdleBlanker? = nil,
        assertions: any KeepAwakeAsserting = SystemKeepAwakeAssertions(),
        notifier: any KeepAwakeNotifying = KeepAwakeNotifier(),
        now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter,
        log: ChorusLog = .display,
        assertionVerifyInterval: Double = 60,
        reevaluationCoalesce: Duration = .milliseconds(250)
    ) {
        self.settings = settings
        self.displayManager = displayManager
        let hub = sourceHub ?? KeepAwakeSourceHub(agentActivity: agentActivity)
        self.sourceHub = hub
        self.lidGuard = lidGuard ?? LidSleepGuardController(
            settings: settings, notifier: notifier
        )
        self.systemLoad = systemLoad
        self.powerSource = powerSource
        self.idleBlanker = idleBlanker ?? AgentIdleBlanker(displays: displayManager)
        self.assertions = assertions
        self.notifier = notifier
        self.now = now
        self.workspaceNotifications = workspaceNotifications
        self.log = log
        self.assertionVerifyInterval = max(1, assertionVerifyInterval)
        self.reevaluationCoalesce = reevaluationCoalesce
        alsoPreventSystemSleep = settings.keepAwakePreventsSystemSleep
        batteryFloor = settings.keepAwakeBatteryFloor
        agentProcessDetectionEnabled = settings.keepAwakeProcessDetection
        agentCustomProcessNames = settings.keepAwakeCustomProcessNames
        agentIdleBlankEnabled = settings.keepAwakeAgentIdleBlankEnabled
        agentIdleBlankMinutes = settings.keepAwakeAgentIdleMinutes
        hub.configure(settings.keepAwakeSourceSettings)
        hub.onBusyChanged = { [weak self] in
            guard let self else { return }
            // busy 布林翻轉要同步（lease hold／grace 邊界）；細節變更可 coalesce。
            let flipped = self.lastInputSnapshot.map { $0.hubBusy != self.sourceHub.isBusy } ?? true
            self.requestReevaluation(reason: .hub, urgency: flipped ? .immediate : .normal)
        }
        self.lidGuard.onChange = { [weak self] in
            self?.requestReevaluation(reason: .lid, urgency: .normal)
        }
        systemLoad.onDecisionChanged = { [weak self] in
            guard let self else { return }
            let flipped = self.lastInputSnapshot.map {
                $0.loadShouldHold != self.systemLoad.evaluation.shouldHold
            } ?? true
            self.requestReevaluation(reason: .load, urgency: flipped ? .immediate : .normal)
        }
        powerSource.onChange = { [weak self] in
            self?.handlePowerSourceChange()
        }
        // `didSet` 在 init 裡不會跑，設定得在這裡自己推一次給 monitor。
        hub.agentActivity.configureProcessDetection(
            enabled: agentProcessDetectionEnabled, customProcessNames: agentCustomProcessNames
        )
    }

    func resetReevaluationStatsForTesting() {
        reevaluationStats = KeepAwakeReevaluationStats()
    }

    /// 測試用：取消 debounce 並立即跑一輪（若有待排）。
    func flushCoalescedReevaluationForTesting() {
        let hadPending = coalesceDeadline != nil || coalesceTask != nil
        cancelCoalescedReevaluation()
        if hadPending {
            requestReevaluation(reason: .pending, urgency: .immediate)
        }
    }

    /// 選單明確選用：寫入互斥持久化旗標，再 activate。
    func selectMode(_ mode: KeepAwakeMode) {
        settings.keepAwakeDisplayUUID = nil
        settings.keepAwakeAppBundleID = nil
        settings.keepAwakeAgentMode = false
        settings.keepAwakeSystemLoadMode = false
        switch mode {
        case let .whileDisplayConnected(uuid):
            settings.keepAwakeDisplayUUID = uuid
        case let .whileAppRunning(bundleID):
            settings.keepAwakeAppBundleID = bundleID
        case .whileAgentsWorking:
            // 合併模式沿用 agent 旗標；legacy load 旗標只讀不寫 true。
            settings.keepAwakeAgentMode = true
            settings.keepAwakeSystemLoadMode = false
        case .off, .duration, .indefinite:
            break
        }
        activate(mode)
    }

    /// 啟動還原：螢幕 > App > (agent ∨ legacy load)；正規化殘留 key。
    func restoreSavedMode() {
        let display = settings.keepAwakeDisplayUUID
        let app = settings.keepAwakeAppBundleID
        let agent = settings.keepAwakeAgentMode
        let load = settings.keepAwakeSystemLoadMode

        if let display {
            settings.keepAwakeAppBundleID = nil
            settings.keepAwakeAgentMode = false
            settings.keepAwakeSystemLoadMode = false
            activate(.whileDisplayConnected(uuid: display))
        } else if let app {
            settings.keepAwakeAgentMode = false
            settings.keepAwakeSystemLoadMode = false
            activate(.whileAppRunning(bundleID: app))
        } else if agent || load {
            settings.keepAwakeAgentMode = true
            settings.keepAwakeSystemLoadMode = false
            activate(.whileAgentsWorking)
        }
    }

    /// 備份匯入後讓執行中的 runtime 跟上持久化設定（restore 只在啟動時跑一次）。
    /// 先同步 controller 快取／來源／負載設定，再對齊會持久化的三類綁定模式；
    /// `duration`／`indefinite` 不存檔，模式本身不受影響，但快取仍會更新。
    /// 結果模式與目前相同就不重啟，避免重置 `startedAt`；負載 config 未變則不重啟 monitor。
    func syncModeWithSettings() {
        syncRuntimeCachesFromSettings()

        let target: KeepAwakeMode? = if let display = settings.keepAwakeDisplayUUID {
            .whileDisplayConnected(uuid: display)
        } else if let app = settings.keepAwakeAppBundleID {
            .whileAppRunning(bundleID: app)
        } else if settings.keepAwakeAgentMode || settings.keepAwakeSystemLoadMode {
            .whileAgentsWorking
        } else {
            nil
        }
        if let target {
            if mode != target {
                restoreSavedMode()
            } else {
                normalizeSavedFlags()
                applyPersistedSystemLoadConfigurationIfNeeded()
            }
            return
        }
        switch mode {
        case .whileDisplayConnected, .whileAppRunning, .whileAgentsWorking:
            activate(.off)
        default:
            break
        }
    }

    /// 匯入後把 SettingsStore 推回 controller／hub／idle blanker 快取。
    /// 先擷取 snapshot，再寫入；setter 的 didSet 會回寫同值並觸發必要的 reevaluate。
    private func syncRuntimeCachesFromSettings() {
        let prevents = settings.keepAwakePreventsSystemSleep
        let floor = settings.keepAwakeBatteryFloor
        let processDetection = settings.keepAwakeProcessDetection
        let customNames = settings.keepAwakeCustomProcessNames
        let idleEnabled = settings.keepAwakeAgentIdleBlankEnabled
        let idleMinutes = settings.keepAwakeAgentIdleMinutes
        let sourceSettings = settings.keepAwakeSourceSettings

        alsoPreventSystemSleep = prevents
        batteryFloor = floor
        agentCustomProcessNames = customNames
        agentProcessDetectionEnabled = processDetection
        agentIdleBlankEnabled = idleEnabled
        agentIdleBlankMinutes = idleMinutes
        sourceHub.configure(sourceSettings)
    }

    /// 已在合併模式時，只在負載 configuration 實際變更才套用（相同則保留遲滯）。
    private func applyPersistedSystemLoadConfigurationIfNeeded() {
        guard case .whileAgentsWorking = mode else { return }
        let normalized = settings.keepAwakeSystemLoadConfiguration.normalized()
        if settings.keepAwakeSystemLoadConfiguration != normalized {
            settings.keepAwakeSystemLoadConfiguration = normalized
        }
        if systemLoad.applyConfiguration(normalized) {
            requestReevaluation(reason: .settings, urgency: .immediate)
        }
    }

    private func normalizeSavedFlags() {
        if case .whileAgentsWorking = mode {
            settings.keepAwakeAgentMode = true
            settings.keepAwakeSystemLoadMode = false
        }
    }

    /// 套用負載門檻：清 latch、不切 mode；合併模式中即時重啟採樣。
    func applySystemLoadConfiguration(_ value: SystemLoadConfiguration) {
        let normalized = value.normalized()
        settings.keepAwakeSystemLoadConfiguration = normalized
        if case .whileAgentsWorking = mode {
            systemLoad.applyConfiguration(normalized)
            requestReevaluation(reason: .settings, urgency: .immediate)
        }
    }

    func activate(_ mode: KeepAwakeMode) {
        guard !shutDown || mode == .off else { return }
        self.mode = mode
        startedAt = mode == .off ? nil : now()
        lastInputSnapshot = nil
        updateAppObservers()
        updateWakeObservers()
        updateAgentMonitor()
        updateSystemLoadMonitor()
        updatePowerSourceMonitor()
        let urgency: KeepAwakeReevaluationUrgency = mode == .off ? .safety : .immediate
        requestReevaluation(reason: .settings, urgency: urgency)
        // 長亮期間持續核對 assertion；建立失敗或失效後仍須重試。
        tickTask?.cancel()
        tickTask = nil
        if mode != .off {
            let interval: Duration
            switch mode {
            case .duration: interval = .seconds(1)
            case .whileAgentsWorking: interval = .seconds(5)
            default: interval = .seconds(10)
            }
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: interval) } catch { return }
                    guard !Task.isCancelled, let self, self.mode != .off else { return }
                    if case .whileAgentsWorking = self.mode {
                        self.systemLoad.evaluate(now: self.now())
                    }
                    self.requestReevaluation(reason: .tick, urgency: .immediate)
                }
            }
        }
    }

    func deactivate() {
        activate(.off)
    }

    /// 顯示器組合變更 → 重新評估「接著某台螢幕時防睡眠」；合併模式重探 GPU。
    func displaysDidChange() {
        if case .whileDisplayConnected = mode {
            requestReevaluation(reason: .displays, urgency: .immediate)
        }
        if case .whileAgentsWorking = mode {
            systemLoad.invalidateGPUCapability()
        }
    }

    /// App 啟動／結束 → 重新評估「這個 App 執行中才防睡眠」。
    func runningAppsDidChange() {
        guard case .whileAppRunning = mode else { return }
        requestReevaluation(reason: .apps, urgency: .immediate)
    }

    /// App 結束前釋放（核心其實也會自動回收，但明確釋放比較乾淨）。
    /// 使用 runtime `activate(.off)`：不清除已保存偏好。
    /// Lid Guard 必須在 deactivate **之前**同步 set(false)（spec §7.1）。
    func shutdown() {
        shutDown = true
        cancelCoalescedReevaluation()
        lidGuard.shutdown()
        idleBlanker.stop()
        deactivate()
    }

    /// Fi A4：automation／token 清除租約（C09 掛鉤；離開 Agent 由 hub.stop 處理）。
    func clearKeepAwakeLeases() {
        sourceHub.leases.clearImmediately()
    }

    /// C09 HTTP hold — 組裝 assertionEffective／lidEffective（Fi A4）。
    func handleKeepAwakeHold(body: Data) -> AutomationHTTPTransport.Response {
        let decoder = JSONDecoder()
        let request: KeepAwakeHoldRequest
        do {
            request = try decoder.decode(KeepAwakeHoldRequest.self, from: body)
        } catch {
            return .init(
                status: 400,
                json: AutomationHTTPTransport.errorJSON("badRequest", "無法解析 hold 請求")
            )
        }
        let result = sourceHub.leases.hold(id: request.id, ttl: request.ttl)
        switch result {
        case let .held(expiresAt, clampedTTL):
            // Lease notify → hub → reevaluate is sync; re-read effectiveness after.
            requestReevaluation(reason: .hold, urgency: .immediate)
            let uptime = sourceHub.leases.currentUptime()
            let assertion = assertionEffectiveForLease()
            let lid = lidEffectiveForLease()
            let response = KeepAwakeHoldResponse(
                id: request.id,
                expiresIn: max(0, expiresAt - uptime),
                ttl: clampedTTL,
                assertionEffective: assertion,
                lidEffective: lid,
                reason: ineffectiveHoldReason(assertionEffective: assertion, lidEffective: lid)
            )
            return encodeOK(response)
        case .invalidID, .invalidTTL:
            return .init(
                status: 400,
                json: AutomationHTTPTransport.errorJSON("badRequest", "id 或 ttl 不合法")
            )
        case .tooMany:
            return .init(
                status: 429,
                json: AutomationHTTPTransport.errorJSON("tooManyLeases", "租約數已達上限")
            )
        case .clockUnavailable:
            return .init(status: 503,
                json: AutomationHTTPTransport.errorJSON("clockUnavailable", "無法取得租約時鐘，請重試"))
        }
    }

    func handleKeepAwakeRelease(body: Data) -> AutomationHTTPTransport.Response {
        let decoder = JSONDecoder()
        let request: KeepAwakeReleaseRequest
        do {
            request = try decoder.decode(KeepAwakeReleaseRequest.self, from: body)
        } catch {
            return .init(
                status: 400,
                json: AutomationHTTPTransport.errorJSON("badRequest", "無法解析 release 請求")
            )
        }
        let released = sourceHub.leases.release(id: request.id)
        return encodeOK(KeepAwakeReleaseResponse(id: request.id, released: released))
    }

    /// GET status：helper 用快取，不阻塞 main actor 打 XPC（§14.3）。
    func handleKeepAwakeStatus() -> AutomationHTTPTransport.Response {
        let snap = sourceHub.leases.snapshot()
        let uptime = sourceHub.leases.currentUptime()
        let leases = snap.active.map {
            KeepAwakeLeaseStatusDTO(
                id: $0.id,
                expiresIn: max(0, $0.expiresAt - uptime),
                ttl: $0.ttl
            )
        }
        let helperDTO: KeepAwakeHelperStatusDTO? = {
            guard let status = lidGuard.helperStatus else { return nil }
            return KeepAwakeHelperStatusDTO(
                availability: "cached",
                sleepDisabled: status.sleepDisabled,
                setByHelper: status.setByHelper,
                holderCount: status.holderCount,
                callerIsHolder: status.callerIsHolder,
                otherUsersHolding: status.otherUsersHolding,
                lastForcedOffReason: status.lastForcedOffReason
            )
        }()
        let response = KeepAwakeStatusResponse(
            mode: modeWire(mode),
            isHolding: isHolding,
            lidPhase: lidPhaseWire(lidGuard.phase),
            contributing: sourceHub.busy.contributing,
            leases: leases,
            helper: helperDTO,
            assertionEffective: assertionEffectiveForLease(),
            lidEffective: lidEffectiveForLease()
        )
        return encodeOK(KeepAwakeStatusRecoveryWire(response: response, evidence: lidGuard.helperStatus))
    }

    /// 公開同步入口：測試／CLI／UI 依賴同步語意；內部走立即執行且不再自激無界 Task。
    func reevaluate() {
        requestReevaluation(reason: .direct, urgency: .immediate)
    }

    func requestReevaluation(reason: KeepAwakeReevaluationReason, urgency: KeepAwakeReevaluationUrgency) {
        guard !shutDown || reason == .settings || reason == .direct else { return }
        reevaluationStats.triggered += 1
        reevaluationStats.triggeredByReason[reason.rawValue, default: 0] += 1

        switch urgency {
        case .safety, .immediate:
            cancelCoalescedReevaluation()
            let isAgentTick: Bool = {
                guard reason == .tick else { return false }
                if case .whileAgentsWorking = mode { return true }
                return false
            }()
            let force = urgency == .safety
                || reason == .wake
                || reason == .session
                || isAgentTick
                || pendingAssertionVerifyTrigger != nil
            performReevaluation(forceInputChange: force)
        case .normal:
            scheduleCoalescedReevaluation()
        }
    }

    private func handlePowerSourceChange() {
        // review #6：電源通知也標記待驗證。
        markAssertionsNeedVerify(trigger: .power)
        let snapshot = powerSource.snapshot
        let next = PowerFloorPolicy.evaluate(
            snapshot: snapshot,
            floor: batteryFloor,
            previous: pauseReason
        )
        let lidSafety = lidGuard.powerRequiresSafetyBypass(
            snapshot,
            existingFloor: batteryFloor
        )
        if next.isTripped != pauseReason.isTripped || lidSafety {
            requestReevaluation(reason: .power, urgency: .safety)
        } else {
            requestReevaluation(reason: .power, urgency: .normal)
        }
    }

    private func scheduleCoalescedReevaluation() {
        if coalesceDeadline != nil {
            reevaluationStats.coalesced += 1
        }
        let delay = reevaluationCoalesce
        if delay <= .zero {
            // 測試用零延遲：合併到下一個 MainActor 回合，同批仍只排一個 Task。
            coalesceDeadline = ContinuousClock.now
            guard coalesceTask == nil else { return }
            coalesceGeneration &+= 1
            let generation = coalesceGeneration
            coalesceTask = Task { @MainActor [weak self] in
                guard let self,
                      !Task.isCancelled,
                      !self.shutDown,
                      self.coalesceGeneration == generation else { return }
                self.coalesceTask = nil
                self.coalesceDeadline = nil
                self.performReevaluation(forceInputChange: false)
            }
            return
        }
        coalesceDeadline = ContinuousClock.now + delay
        guard coalesceTask == nil else { return }
        coalesceGeneration &+= 1
        let generation = coalesceGeneration
        coalesceTask = Task { @MainActor [weak self] in
            while true {
                guard let self,
                      !Task.isCancelled,
                      !self.shutDown,
                      self.coalesceGeneration == generation else { return }
                guard let deadline = self.coalesceDeadline else { break }
                let remaining = ContinuousClock.now.duration(to: deadline)
                if remaining <= .zero { break }
                do { try await ContinuousClock().sleep(until: deadline) } catch { return }
            }
            guard let self,
                  !Task.isCancelled,
                  !self.shutDown,
                  self.coalesceGeneration == generation else { return }
            self.coalesceTask = nil
            self.coalesceDeadline = nil
            self.performReevaluation(forceInputChange: false)
        }
    }

    private func cancelCoalescedReevaluation() {
        coalesceGeneration &+= 1
        coalesceTask?.cancel()
        coalesceTask = nil
        coalesceDeadline = nil
    }

    private func performReevaluation(forceInputChange: Bool) {
        if reevaluating {
            pendingReevaluate = true
            if forceInputChange {
                forceInputChangeThisPass = true
            }
            return
        }
        reevaluating = true
        let force = forceInputChange || forceInputChangeThisPass
        forceInputChangeThisPass = false
        defer {
            reevaluating = false
            if pendingReevaluate {
                pendingReevaluate = false
                // 不再 Task{reevaluate()} 無界自激；併入 trailing coalesce。
                requestReevaluation(reason: .pending, urgency: .normal)
            }
        }
        if case .whileAgentsWorking = mode {
            sourceHub.configure(settings.keepAwakeSourceSettings)
        }
        let currentTime = now()
        // UI 倒數每輪更新，不因 assertion no-op 凍結。
        remainingSeconds = KeepAwakePlanner.remainingSeconds(mode: mode, startedAt: startedAt, now: currentTime)
        let connected = Set(displayManager?.displays.map(\.uuid) ?? [])
        // 執行中 App 清單每次現查——只有綁定 App 模式會走到，
        // 而那個模式是事件驅動的，不會每秒問一次。
        var running: Set<String> = []
        if case .whileAppRunning = mode { running = RunningApps.bundleIDs() }
        updatePowerFloorState()
        let shouldHold = KeepAwakePlanner.shouldHoldAssertion(
            mode: mode,
            startedAt: startedAt,
            now: currentTime,
            connectedDisplayUUIDs: connected,
            runningAppBundleIDs: running,
            agentsWorking: sourceHub.isBusy,
            systemBusy: systemLoad.evaluation.shouldHold,
            powerFloorTripped: pauseReason.isTripped
        )
        let plan = KeepAwakePlanner.assertionPlan(mode: mode, alsoPreventSystemSleep: alsoPreventSystemSleep)
        let snapshot = ReevaluationInputSnapshot(
            mode: mode,
            startedAt: startedAt,
            shouldHold: shouldHold,
            preventsDisplaySleep: plan.preventsDisplaySleep,
            preventsSystemSleep: plan.preventsSystemSleep,
            hubBusy: sourceHub.isBusy,
            hubReleaseAt: sourceHub.busy.releaseAt,
            hubContributingIDs: sourceHub.busy.contributing.map(\.id),
            loadShouldHold: systemLoad.evaluation.shouldHold,
            loadCooldown: systemLoad.evaluation.cooldownRemaining,
            power: powerSource.snapshot,
            batteryFloor: batteryFloor,
            pauseTripped: pauseReason.isTripped,
            alsoPreventSystemSleep: alsoPreventSystemSleep,
            agentIdleBlankEnabled: agentIdleBlankEnabled,
            agentIdleBlankMinutes: agentIdleBlankMinutes,
            displayConnectedMatch: {
                if case let .whileDisplayConnected(uuid) = mode { return connected.contains(uuid) }
                return nil
            }(),
            appRunningMatch: {
                if case let .whileAppRunning(bundleID) = mode { return running.contains(bundleID) }
                return nil
            }()
        )

        let verifyDue = pendingAssertionVerifyTrigger != nil
            || isAssertionVerifyDue(type: kIOPMAssertionTypePreventUserIdleDisplaySleep, held: displayAssertion != nil)
            || isAssertionVerifyDue(type: kIOPMAssertionTypePreventUserIdleSystemSleep, held: systemAssertion != nil)
        let durationExpired = {
            if case .duration = mode {
                return KeepAwakePlanner.remainingSeconds(mode: mode, startedAt: startedAt, now: currentTime) == 0
            }
            return false
        }()
        // create 失敗後 shouldHold 仍真但尚未持有：不可 no-op，否則永遠不重試。
        let awaitingSuccessfulHold = shouldHold && (
            (plan.preventsDisplaySleep && displayAssertion == nil)
                || (plan.preventsSystemSleep && systemAssertion == nil)
        )
        let skipSideEffects = !force
            && !verifyDue
            && !durationExpired
            && !awaitingSuccessfulHold
            && lastInputSnapshot == snapshot

        reevaluationStats.executed += 1
        if skipSideEffects {
            reevaluationStats.skippedUnchanged += 1
            emitThrottleSummaryIfNeeded(now: currentTime)
            return
        }
        lastInputSnapshot = snapshot

        forceVerifyThisPass = pendingAssertionVerifyTrigger != nil
        verifyTrigger = pendingAssertionVerifyTrigger?.rawValue ?? "heartbeat"
        if forceVerifyThisPass {
            pendingAssertionVerifyTrigger = nil
        }
        if shouldHold {
            if plan.preventsDisplaySleep {
                hold(&displayAssertion, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "Chorus 螢幕長亮")
            } else {
                release(&displayAssertion, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "policy")
            }
            if plan.preventsSystemSleep {
                hold(&systemAssertion, type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: "Chorus 防止系統待機")
            } else {
                release(&systemAssertion, type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: "policy")
            }
        } else {
            release(&displayAssertion, type: kIOPMAssertionTypePreventUserIdleDisplaySleep, reason: "policy")
            release(&systemAssertion, type: kIOPMAssertionTypePreventUserIdleSystemSleep, reason: "policy")
            // 計時到期就把模式收乾淨，UI 才不會停在「開啟中」。
            // 電量／溫度暫停**不收**：倒數照常走，恢復後繼續持有直到時間到。
            // 螢幕／App 綁定模式**不收**：螢幕接回來、App 再開時要能自己恢復。
            if durationExpired {
                mode = .off
                startedAt = nil
                remainingSeconds = nil
                tickTask?.cancel()
                updateWakeObservers()
                updatePowerSourceMonitor()
                lastInputSnapshot = nil
            }
        }
        isHolding = shouldHold
            && (!plan.preventsDisplaySleep || displayAssertion != nil)
            && (!plan.preventsSystemSleep || systemAssertion != nil)
        activationFailed = shouldHold && !isHolding
        updateIdleBlanker()
        // Skeleton: lidGuard.update wired; full set/heartbeat in integration.
        let agentModeActive = {
            if case .whileAgentsWorking = mode { return !shutDown }
            return false
        }()
        lidGuard.update(
            agentModeActive: agentModeActive,
            busy: sourceHub.busy,
            power: powerSource.snapshot,
            existingFloor: batteryFloor
        )
        emitThrottleSummaryIfNeeded(now: currentTime)
    }

    private func emitThrottleSummaryIfNeeded(now currentTime: Double) {
        let last = lastThrottleSummaryAt ?? 0
        guard currentTime - last >= 60 else { return }
        lastThrottleSummaryAt = currentTime
        let stats = reevaluationStats
        log.event(
            KeepAwakeLogEvent.throttleSummary,
            level: .debug,
            fields: [
                "triggered": "\(stats.triggered)",
                "coalesced": "\(stats.coalesced)",
                "executed": "\(stats.executed)",
                "skipped": "\(stats.skippedUnchanged)",
            ]
        )
    }

    /// 輸入快照：相同則略過 assertion／helper／idle blanker 有副作用路徑。
    private struct ReevaluationInputSnapshot: Equatable {
        var mode: KeepAwakeMode
        var startedAt: Double?
        var shouldHold: Bool
        var preventsDisplaySleep: Bool
        var preventsSystemSleep: Bool
        var hubBusy: Bool
        var hubReleaseAt: Date?
        var hubContributingIDs: [String]
        var loadShouldHold: Bool
        var loadCooldown: Double?
        var power: PowerSnapshot
        var batteryFloor: KeepAwakeBatteryFloor
        var pauseTripped: Bool
        var alsoPreventSystemSleep: Bool
        var agentIdleBlankEnabled: Bool
        var agentIdleBlankMinutes: KeepAwakeAgentIdleMinutes
        var displayConnectedMatch: Bool?
        var appRunningMatch: Bool?
    }

    private func updateIdleBlanker() {
        if case .whileAgentsWorking = mode {
            idleBlanker.configure(
                enabled: agentIdleBlankEnabled,
                minutes: agentIdleBlankMinutes
            )
            idleBlanker.update(agentModeActive: true, holdingAssertion: isHolding)
        } else {
            idleBlanker.stop()
        }
    }

    private func updatePowerFloorState() {
        guard mode != .off else {
            pauseReason = .ok
            thermalWarning = false
            didNotifyCurrentTrip = false
            return
        }
        let previous = pauseReason
        let next = PowerFloorPolicy.evaluate(
            snapshot: powerSource.snapshot,
            floor: batteryFloor,
            previous: previous
        )
        pauseReason = next
        thermalWarning = powerSource.snapshot.thermal == .serious && !next.isTripped
        if next.isTripped {
            if !previous.isTripped, !didNotifyCurrentTrip {
                didNotifyCurrentTrip = true
                notifier.notifyPowerFloorPaused(next)
            }
        } else {
            didNotifyCurrentTrip = false
        }
    }

    private func updateWakeObservers() {
        let center = workspaceNotifications
        wakeObservers.forEach { center.removeObserver($0) }
        wakeObservers = []
        if let sleepObserver {
            center.removeObserver(sleepObserver)
            self.sleepObserver = nil
        }
        guard mode != .off else { return }

        sleepObserver = center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWillSleep() }
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            wakeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let isWake = note.name == NSWorkspace.didWakeNotification
                MainActor.assumeIsolated {
                    guard let self, !self.shutDown else { return }
                    if isWake {
                        self.handleDidWake()
                    } else {
                        self.markAssertionsNeedVerify(trigger: .session)
                        self.requestReevaluation(reason: .session, urgency: .immediate)
                    }
                }
            })
        }
    }

    private func handleWillSleep() {
        if case .whileAgentsWorking = mode {
            // 只停負載取樣；不要無條件放掉 assertion，否則 agent 持有會在睡前被拆掉。
            systemLoad.stop()
            requestReevaluation(reason: .sleep, urgency: .immediate)
        }
    }

    private func handleDidWake() {
        guard !shutDown else { return }
        if case .whileAgentsWorking = mode {
            systemLoad.resetAfterWake()
            // V1-7: refresh lease expiry/grace and recompute hub busy *before* assertion/Lid
            // evaluation so a sleep past TTL+grace cannot keep stale isWorkingNow busy.
            sourceHub.tick()
        }
        // Refresh helper status in the background; assertion reevaluate stays synchronous
        // so existing wake／duration tests keep working.
        Task { @MainActor [weak self] in
            await self?.lidGuard.refreshFromHelper()
        }
        markAssertionsNeedVerify(trigger: .wake)
        // 喚醒必須繞過「輸入沒變」捷徑（P1-3 → P2）。
        requestReevaluation(reason: .wake, urgency: .immediate)
    }

    private func markAssertionsNeedVerify(trigger: AssertionVerifyTrigger) {
        pendingAssertionVerifyTrigger = trigger
    }

    /// 合併模式進出時開／關來源 hub（含既有 agents＋新來源）。
    private func updateAgentMonitor() {
        if case .whileAgentsWorking = mode {
            sourceHub.configure(settings.keepAwakeSourceSettings)
            sourceHub.start()
        } else {
            sourceHub.stop()
        }
    }

    private func updateSystemLoadMonitor() {
        if case .whileAgentsWorking = mode {
            systemLoad.start(configuration: settings.keepAwakeSystemLoadConfiguration)
        } else {
            systemLoad.stop()
        }
    }

    private func updatePowerSourceMonitor() {
        if mode == .off {
            powerSource.stop()
            pauseReason = .ok
            thermalWarning = false
            didNotifyCurrentTrip = false
        } else {
            powerSource.start()
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
        var recreating = false
        var previousID: IOPMAssertionID?
        if let existing = id {
            // 本程序已成功建立且尚未釋放：穩態不查 IOPMAssertionCopyProperties。
            // display／system 各自判斷保底；喚醒等 force 則兩者都查。
            guard forceVerifyThisPass || isAssertionVerifyDue(type: type, held: true) else { return }
            setAssertionVerifyAt(type: type, at: now())
            if assertions.isActive(existing) { return }
            previousID = existing
            assertions.release(existing)
            id = nil
            recreating = true
            let label = Self.assertionTypeLabel(type)
            log.event(
                KeepAwakeLogEvent.assertionReleased,
                level: .notice,
                fields: [
                    "type": label,
                    "id": "\(existing)",
                    "reason": "inactive",
                    "trigger": verifyTrigger,
                ]
            )
        }
        guard let created = assertions.create(type: type, reason: reason) else {
            id = nil
            if recreating, let previousID {
                let label = Self.assertionTypeLabel(type)
                log.event(
                    KeepAwakeLogEvent.assertionRecreated,
                    level: .notice,
                    fields: [
                        "type": label,
                        "trigger": verifyTrigger,
                        "result": "failed",
                        "previousId": "\(previousID)",
                    ]
                )
            }
            return
        }
        id = created
        // 只推進「這個 type」的期限；不得延後另一類未檢查的舊 ID。
        setAssertionVerifyAt(type: type, at: now())
        let label = Self.assertionTypeLabel(type)
        if recreating {
            log.event(
                KeepAwakeLogEvent.assertionRecreated,
                level: .notice,
                fields: [
                    "type": label,
                    "id": "\(created)",
                    "trigger": verifyTrigger,
                    "previousId": previousID.map { "\($0)" } ?? "",
                ].filter { !$0.value.isEmpty }
            )
        } else {
            log.event(
                KeepAwakeLogEvent.assertionCreated,
                level: .notice,
                fields: ["type": label, "id": "\(created)"]
            )
        }
    }

    private func isAssertionVerifyDue(type: String, held: Bool) -> Bool {
        guard held else { return false }
        guard let last = assertionVerifyAt(type: type) else { return false }
        return now() - last >= assertionVerifyInterval
    }

    private func assertionVerifyAt(type: String) -> Double? {
        if type == kIOPMAssertionTypePreventUserIdleDisplaySleep {
            return lastDisplayAssertionVerifyAt
        }
        if type == kIOPMAssertionTypePreventUserIdleSystemSleep {
            return lastSystemAssertionVerifyAt
        }
        return nil
    }

    private func setAssertionVerifyAt(type: String, at time: Double) {
        if type == kIOPMAssertionTypePreventUserIdleDisplaySleep {
            lastDisplayAssertionVerifyAt = time
        } else if type == kIOPMAssertionTypePreventUserIdleSystemSleep {
            lastSystemAssertionVerifyAt = time
        }
    }

    private func release(_ id: inout IOPMAssertionID?, type: String, reason: String = "policy") {
        guard let existing = id else { return }
        assertions.release(existing)
        id = nil
        log.event(
            KeepAwakeLogEvent.assertionReleased,
            level: .notice,
            fields: [
                "type": Self.assertionTypeLabel(type),
                "id": "\(existing)",
                "reason": reason,
            ]
        )
    }

    private static func assertionTypeLabel(_ type: String) -> String {
        if type == kIOPMAssertionTypePreventUserIdleDisplaySleep { return "display" }
        if type == kIOPMAssertionTypePreventUserIdleSystemSleep { return "system" }
        return "other"
    }

    private func assertionEffectiveForLease() -> Bool {
        guard case .whileAgentsWorking = mode, !shutDown else { return false }
        return isHolding
    }

    private func lidEffectiveForLease() -> Bool {
        guard case .whileAgentsWorking = mode, !shutDown else { return false }
        return lidGuard.isActuallyHoldingSleepDisabled
    }

    /// Spec §4.5 / C8-7: explain ineffective assertion and/or Lid Guard sides independently.
    /// Precedence when both ineffective: agentModeOff → lidGuardOff → blocked:<lid|power|assertion>.
    /// Partial cases (one side effective) still surface the inactive side's explanation.
    private func ineffectiveHoldReason(assertionEffective: Bool, lidEffective: Bool) -> String? {
        if assertionEffective, lidEffective { return nil }

        if case .whileAgentsWorking = mode, !shutDown {
            /// Explicit lid blockers only; bare “enabled but not holding” defers to assertion.
            let explicitLidReason: String? = {
                if lidEffective { return nil }
                if !lidGuard.settings.enabled { return "lidGuardOff" }
                if let blocked = lidBlockReasonWire(lidGuard.phase) {
                    return "blocked:\(blocked)"
                }
                if pauseReason.isTripped { return "blocked:powerFloor" }
                return nil
            }()
            let assertionReason: String? = assertionEffective ? nil : "blocked:assertionFailed"

            if !assertionEffective, !lidEffective {
                return explicitLidReason ?? assertionReason ?? "lidGuardOff"
            }
            // Partial: explain the ineffective side (lid fallback when enabled but not holding).
            if !lidEffective {
                if let explicitLidReason { return explicitLidReason }
                if case .unavailable = lidGuard.phase { return "blocked:helperUnavailable" }
                return "blocked:lidPending"
            }
            return assertionReason
        }
        return "agentModeOff"
    }

    private func lidBlockReasonWire(_ phase: LidSleepGuardPhase) -> String? {
        guard case let .blocked(reason) = phase else { return nil }
        switch reason {
        case .lowBattery: return "lowBattery"
        case .thermal: return "thermal"
        case .maxDuration: return "maxDuration"
        case .userPaused: return "userPaused"
        case .noLid: return "noLid"
        case .lidUnknown: return "lidUnknown"
        case .unknownPower: return "unknownPower"
        }
    }

    private func encodeOK<T: Encodable>(_ value: T) -> AutomationHTTPTransport.Response {
        let data = (try? JSONEncoder().encode(value)) ?? Data("{}".utf8)
        return .init(status: 200, json: String(decoding: data, as: UTF8.self))
    }

    private func modeWire(_ mode: KeepAwakeMode) -> String {
        switch mode {
        case .off: return "off"
        case .indefinite: return "indefinite"
        case .duration: return "duration"
        case .whileDisplayConnected: return "whileDisplayConnected"
        case .whileAppRunning: return "whileAppRunning"
        case .whileAgentsWorking: return "whileAgentsWorking"
        }
    }

    private func lidPhaseWire(_ phase: LidSleepGuardPhase) -> String {
        switch phase {
        case .off: return "off"
        case .unavailable: return "unavailable"
        case .idle: return "idle"
        case .armed: return "armed"
        case .holdingLidClosed: return "holdingLidClosed"
        case .blocked: return "blocked"
        }
    }

}

/// C08's additive HTTP allowlist. Keep C01's existing DTO decodable while its
/// owner adds optional recovery fields; encode only these three health booleans.
private struct KeepAwakeStatusRecoveryWire: Encodable {
    let response: KeepAwakeStatusResponse
    let evidence: PowerHelperStatus?

    private enum CodingKeys: String, CodingKey { case helper }

    func encode(to encoder: Encoder) throws {
        try response.encode(to: encoder)
        guard let cached = response.helper, let evidence else { return }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(HelperRecoveryWire(cached: cached, evidence: evidence), forKey: .helper)
    }

    private struct HelperRecoveryWire: Encodable {
        let cached: KeepAwakeHelperStatusDTO
        let evidence: PowerHelperStatus

        private enum CodingKeys: String, CodingKey {
            case recoveryBlocked, pendingRestore, persistRetryNeeded
        }

        func encode(to encoder: Encoder) throws {
            try cached.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(evidence.recoveryBlocked, forKey: .recoveryBlocked)
            try container.encode(evidence.pendingRestore, forKey: .pendingRestore)
            try container.encode(evidence.persistRetryNeeded, forKey: .persistRetryNeeded)
        }
    }
}
