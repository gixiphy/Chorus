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
        let level = (properties[kIOPMAssertionLevelKey] as? NSNumber)?.uint32Value
        return level == UInt32(kIOPMAssertionLevelOn)
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
            reevaluate()
        }
    }

    /// 用電池時的電量底線；溫度臨界不受此設定影響。
    var batteryFloor: KeepAwakeBatteryFloor {
        didSet {
            guard batteryFloor != oldValue else { return }
            settings.keepAwakeBatteryFloor = batteryFloor
            reevaluate()
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
    @ObservationIgnored private var displayAssertion: IOPMAssertionID?
    @ObservationIgnored private var systemAssertion: IOPMAssertionID?
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
        workspaceNotifications: NotificationCenter = NSWorkspace.shared.notificationCenter
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
        alsoPreventSystemSleep = settings.keepAwakePreventsSystemSleep
        batteryFloor = settings.keepAwakeBatteryFloor
        agentProcessDetectionEnabled = settings.keepAwakeProcessDetection
        agentCustomProcessNames = settings.keepAwakeCustomProcessNames
        agentIdleBlankEnabled = settings.keepAwakeAgentIdleBlankEnabled
        agentIdleBlankMinutes = settings.keepAwakeAgentIdleMinutes
        hub.configure(settings.keepAwakeSourceSettings)
        hub.onBusyChanged = { [weak self] in self?.reevaluate() }
        self.lidGuard.onChange = { [weak self] in self?.reevaluate() }
        systemLoad.onDecisionChanged = { [weak self] in self?.reevaluate() }
        powerSource.onChange = { [weak self] in self?.reevaluate() }
        // `didSet` 在 init 裡不會跑，設定得在這裡自己推一次給 monitor。
        hub.agentActivity.configureProcessDetection(
            enabled: agentProcessDetectionEnabled, customProcessNames: agentCustomProcessNames
        )
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
            reevaluate()
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
            reevaluate()
        }
    }

    func activate(_ mode: KeepAwakeMode) {
        guard !shutDown || mode == .off else { return }
        self.mode = mode
        startedAt = mode == .off ? nil : now()
        updateAppObservers()
        updateWakeObservers()
        updateAgentMonitor()
        updateSystemLoadMonitor()
        updatePowerSourceMonitor()
        reevaluate()
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
                    self.reevaluate()
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
            reevaluate()
        }
        if case .whileAgentsWorking = mode {
            systemLoad.invalidateGPUCapability()
        }
    }

    /// App 啟動／結束 → 重新評估「這個 App 執行中才防睡眠」。
    func runningAppsDidChange() {
        guard case .whileAppRunning = mode else { return }
        reevaluate()
    }

    /// App 結束前釋放（核心其實也會自動回收，但明確釋放比較乾淨）。
    /// 使用 runtime `activate(.off)`：不清除已保存偏好。
    /// Lid Guard 必須在 deactivate **之前**同步 set(false)（spec §7.1）。
    func shutdown() {
        shutDown = true
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
            reevaluate()
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

    func reevaluate() {
        if reevaluating {
            pendingReevaluate = true
            return
        }
        reevaluating = true
        defer {
            reevaluating = false
            if pendingReevaluate {
                pendingReevaluate = false
                // Async — bound callback depth independently of hub/lease sync notify (V1-2).
                Task { @MainActor [weak self] in
                    self?.reevaluate()
                }
            }
        }
        if case .whileAgentsWorking = mode {
            sourceHub.configure(settings.keepAwakeSourceSettings)
        }
        let currentTime = now()
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
            // 電量／溫度暫停**不收**：倒數照常走，恢復後繼續持有直到時間到。
            // 螢幕／App 綁定模式**不收**：螢幕接回來、App 再開時要能自己恢復。
            if case .duration = mode,
               KeepAwakePlanner.remainingSeconds(mode: mode, startedAt: startedAt, now: currentTime) == 0 {
                mode = .off
                startedAt = nil
                remainingSeconds = nil
                tickTask?.cancel()
                updateWakeObservers()
                updatePowerSourceMonitor()
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
                        self.reevaluate()
                    }
                }
            })
        }
    }

    private func handleWillSleep() {
        if case .whileAgentsWorking = mode {
            // 只停負載取樣；不要無條件放掉 assertion，否則 agent 持有會在睡前被拆掉。
            systemLoad.stop()
            reevaluate()
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
        reevaluate()
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
