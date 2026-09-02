import AudioToolbox
import ChorusCore
import CoreAudio
import Foundation
import Observation
import os

/// Process tap 引擎（B6-1 基礎設施、B6-2 per-app 調整、B6-3 路由、
/// B6-4 裝置級軟體音量）。
///
/// 職責：權限流程（DESIGN §1.2 定稿）、tap session 生命週期、健康判讀、
/// 裝置變更時搬家，以及**讓進行中的 session 與使用者設定一致**。
///
/// 權限流程（沒有任何 API 能查詢，只能靠行為判讀）：
/// 啟用 → captureOnly 探測 session（AudioDeviceStart 觸發系統對話框）→
/// 每秒餵 TapHealthMonitor → healthy＝權限有、收探測進 active／
/// denied＝收探測進 denied、引導去系統設定。
///
/// **設定是 tap 的唯一來源**（B6-2）：`settings.appAudio` 裡有一筆非
/// neutral 的紀錄才會有 session。沒調整的 App 一個 tap 都不建
/// （DESIGN §2.3 規則 2），關掉調整就立刻收掉——不是「留著 tap 但不處理」。
@MainActor
@Observable
final class TapEngine {
    enum State: Equatable {
        case off
        /// 探測中。權限被拒**不會有任何錯誤**，只能等健康判讀；
        /// 系統無聲時判不了——UI 要提示「播放任何聲音以完成確認」。
        case probing
        /// 權限確認、基礎設施就緒。有沒有 tap 取決於使用者調了幾個 App。
        case active
        /// 判定權限缺失（連續「發聲卻全零」）。
        case denied
        case failed(String)
    }

    /// Release 版唯一的觀測窗口：`log stream --predicate 'subsystem == "com.hermes.Chorus"'`。
    /// 2026-08-30 的教訓：引擎在使用者機器上靜靜死掉，黑箱查了一小時。
    @ObservationIgnored private let log = ChorusLog(category: "taps")

    private(set) var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            log.notice("state: \(String(describing: oldValue)) → \(String(describing: self.state))")
            // AudioDeviceManager 要重算三後端矩陣：軟體音量只有在引擎
            // 拿到權限後才成立，狀態一變滑桿的可用性就跟著變
            stateChangedHandler?()
        }
    }
    /// 狀態變更回呼（AppState 接到 AudioDeviceManager.refreshBridges）。
    @ObservationIgnored var stateChangedHandler: (@MainActor () -> Void)?
    /// 進行中的 per-app session（排序後的 bundleID）。
    private(set) var tappedBundles: [String] = []
    /// 探測的即時統計（設定頁顯示用）。
    private(set) var probeStats = TapSessionStats()
    /// 最近一次「單一 App 接管失敗」的說明。**不改 state**——
    /// 一個 App 的 tap 建不起來不該讓整個引擎離開 active
    /// （CrashGuard 的行為教訓：失敗要隔離在 session 層）。
    private(set) var lastTapError: String?

    @ObservationIgnored private let backend: any TapBackend
    @ObservationIgnored let registry: AudioProcessRegistry
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var probeSession: (any TapSession)?
    @ObservationIgnored private var sessions: [String: any TapSession] = [:]
    /// 每條 session 實際建在哪個裝置的 UID 上。存它才分得出「設定改了但
    /// 裝置沒變」（推 atomic 就好）與「裝置換了」（非重建不可）。
    @ObservationIgnored private var sessionOutputUIDs: [String: String] = [:]
    /// 每條 session 的 tap 描述涵蓋了哪些 bundle（root＋helper）。
    /// 新成員出現才重建；成員消失不動——`processRestoreEnabled` 靠的
    /// 就是描述留著，App 重啟由系統重綁。
    @ObservationIgnored private var sessionMemberBundles: [String: Set<String>] = [:]
    /// 裝置級處理的一條全域 session（B6-4 軟體音量＋B6-5 等化共用）。
    @ObservationIgnored private var globalSession: (any TapSession)?
    @ObservationIgnored private var globalOutputUID: String?
    @ObservationIgnored private var globalExclusions: [AudioObjectID] = []
    @ObservationIgnored private var deviceTarget: String?
    @ObservationIgnored private var deviceGain: Float = 1
    @ObservationIgnored private var deviceMuted = false
    @ObservationIgnored private var deviceEQ: EQSettings?
    /// 裝置級軟體平衡（−1…+1）。只有沒有原生平衡的裝置會送非零值進來。
    @ObservationIgnored private var deviceBalance: Float = 0
    /// 裝置級 AU 效果鏈（AU-2b）。存的是完整清單；推給 session 前
    /// 過 `loadableEffects`（enabled ＋ 不在隔離名單）。
    @ObservationIgnored private var deviceEffects: [AUEffectEntry] = []
    @ObservationIgnored private var monitor = TapHealthMonitor()
    @ObservationIgnored private var lastProbeStats = TapSessionStats()
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// 延遲重建（裝置重新配置後鏈路要 1–2 秒才穩）與失敗重試的排程。
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private var rebuildRetries = 0
    /// 測試把它調成 .zero；正式值對齊 driver 端「目標重新出現等 1.5 秒」。
    @ObservationIgnored var rebuildDelay: Duration = .seconds(1.5)

    init(backend: any TapBackend, registry: AudioProcessRegistry, settings: SettingsStore) {
        self.backend = backend
        self.registry = registry
        self.settings = settings
        backend.setDefaultOutputChangedHandler { [weak self] in
            self?.defaultOutputChanged()
        }
        // helper 出現時 tap 描述要補上它（聲音多半從 helper 出來），
        // 全域 tap 的排除清單也要跟著長
        registry.onProcessesChanged = { [weak self] in
            self?.reconcileSessions()
        }
    }

    /// App 啟動時呼叫：上次已啟用就直接重新探測（TCC 已給過的話
    /// 幾秒內就會轉 active，沒有對話框），轉 active 後 reconcile 會把
    /// 上次的 per-app 設定重新套上——**App 重啟自動恢復**（B6-2 驗收項）。
    func start() {
        if settings.audioTapsEnabled {
            beginProbe()
        }
    }

    func setEnabled(_ enabled: Bool) {
        settings.audioTapsEnabled = enabled
        if enabled {
            beginProbe()
        } else {
            shutdownSessions()
            state = .off
        }
    }

    /// denied 後使用者到系統設定改了權限 → 重試。
    func retryPermission() {
        guard settings.audioTapsEnabled else { return }
        beginProbe()
    }

    // MARK: - per-app 調整（B6-2）

    func setting(for bundleID: String) -> AppAudioSetting {
        settings.appAudio[bundleID]
    }

    /// 0–4x。>1 由 realtime 端的 `SoftClip` 保護。
    func setGain(_ gain: Float, bundleID: String) {
        update(bundleID: bundleID) { $0.gain = AppAudioSetting.snapGain(gain) }
    }

    func setMuted(_ muted: Bool, bundleID: String) {
        update(bundleID: bundleID) { $0.muted = muted }
    }

    func toggleMuted(bundleID: String) {
        setMuted(!setting(for: bundleID).muted, bundleID: bundleID)
    }

    /// 指定輸出裝置；`nil` ＝跟隨系統預設（B6-3）。
    /// App 層等化（B6-8）。設定是唯一來源——寫進 appAudio 再對帳，
    /// 與 gain／mute／路由同一條路。
    func setAppEQ(_ eq: EQSettings?, bundleID: String) {
        update(bundleID: bundleID) { $0.eq = eq }
    }

    /// App 層 AU 效果鏈（B6-8 AU-2b）。與 EQ 同一條設定驅動的路。
    func setAppEffects(_ effects: [AUEffectEntry], bundleID: String) {
        update(bundleID: bundleID) { $0.effects = effects }
    }

    func setOutputDevice(_ uid: String?, bundleID: String) {
        update(bundleID: bundleID) { $0.outputDeviceUID = uid }
    }

    /// 回到完全原生的路徑（清掉這個 App 的所有調整，tap 隨之消失）。
    func reset(bundleID: String) {
        var all = settings.appAudio
        all.reset(bundleID: bundleID)
        settings.appAudio = all
        reconcileSessions()
    }

    // MARK: - 排除清單（Excluded Applications）

    /// 這個 App 是否被排除於所有音訊處理之外。
    func isExcluded(bundleID: String) -> Bool {
        settings.excludedApps.contains(bundleID)
    }

    /// 排除／重新納入。排除＝「Chorus 完全不碰這個 App 的音訊」：
    /// per-app tap 不建（既有調整**保留**、只是不生效——與「EQ 存著但
    /// 關掉」同一態度），裝置級全域 tap 也把它的行程排除。這是 DAW、
    /// 遊戲、視訊會議在裝置 EQ／軟體音量開著時退出處理鏈的唯一出口。
    func setExcluded(_ excluded: Bool, bundleID: String) {
        var apps = settings.excludedApps
        if excluded { apps.insert(bundleID) } else { apps.remove(bundleID) }
        guard apps != settings.excludedApps else { return }
        settings.excludedApps = apps
        log.notice("排除清單\(excluded ? "加入" : "移除")：\(bundleID)")
        reconcileSessions()
    }

    private func update(bundleID: String, _ mutate: (inout AppAudioSetting) -> Void) {
        var all = settings.appAudio
        let before = all[bundleID]
        var entry = before
        mutate(&entry)
        all[bundleID] = entry
        settings.appAudio = all
        log.info("App 設定 \(bundleID)：gain=\(entry.gain) muted=\(entry.muted) route=\(entry.outputDeviceUID ?? "預設") eq=\(entry.eq?.isEnabled ?? false) effects=\(entry.effects.count)")
        // 快路徑：只有 gain／mute 在動（滑桿拖動每秒 30–60 個 tick），
        // session 存在且組成、路由、EQ 都沒變 → 推 atomic 就好。全量對帳
        // 一次要列舉兩輪 HAL 裝置清單，在拖動路徑上是主執行緒的大宗浪費。
        // session 不在（建立失敗後重試耗盡）就照舊走全量——設定變更
        // 本來就是讓它復活的自然事件之一。
        if sessions[bundleID] != nil,
           entry.needsTap, before.needsTap,
           entry.outputDeviceUID == before.outputDeviceUID,
           entry.eq == before.eq, entry.effects == before.effects {
            pushSessionProcessing(bundleID)
            return
        }
        reconcileSessions()
    }

    /// 音訊裝置清單變了（插拔耳機、虛擬裝置上線）。指定路由的 App
    /// 可能因此**找回**它的目標裝置，所以要重新對帳。
    func audioDevicesChanged() {
        // failed 與 denied 都不該是終態。failed：啟動撞上裝置空窗。
        // denied：探測期間撞上藍牙重協商——「來源發聲 × 全零」兩格就
        // latch，TCC 明明允許也會被誤判（anc-log 實測：引擎死在 denied，
        // 整輪 EQ 靜靜缺席）。裝置面貌一變就延遲重探測；真被拒的話
        // 重探測還是 denied，不會跳對話框（TCC 已有決定），指引照常顯示。
        switch state {
        case .failed, .denied:
            guard settings.audioTapsEnabled else { return }
            scheduleRebuild(after: rebuildDelay) { engine in
                if case .active = engine.state { return } // 期間已經活了就別打斷
                engine.beginProbe(afterDeviceEvent: true)
            }
        case .probing:
            // 探測中撞上裝置清單變動：那段的全零不算證據。
            // **刻意不重建 probe**——首次啟用時 TCC 對話框正在畫面上，
            // 裝置清單抖一下就收舊建新會把對話框扯掉重出。
            monitor.noteDeviceChanged()
        default:
            reconcileSessions()
        }
    }

    // MARK: - 裝置級處理（B6-4 軟體音量＋B6-5 等化）

    /// 目前有沒有一條裝置級全域 tap 在跑，跑在哪個裝置上。
    ///
    /// **軟體音量與 EQ 共用同一條**：兩者都是「這個裝置的全部音訊」，
    /// 各開一條就是同一路音訊被 tap 兩次（DESIGN §2.2 明確禁止）。
    private(set) var deviceTapUID: String?

    /// AudioDeviceManager 的唯一入口：`deviceUID` 為 `nil` ＝ 收掉。
    ///
    /// 增益不存在這裡——裝置音量的持久化本來就在 `SettingsStore.lastVolume`、
    /// EQ 在 `SettingsStore.deviceEQ`，再存一份只會多一個會不同步的來源。
    func updateDeviceProcessing(
        deviceUID: String?, gain: Float, muted: Bool, eq: EQSettings?,
        balance: Float = 0, effects: [AUEffectEntry] = []
    ) {
        let gain = AppAudioSetting.clampGain(gain)
        let balance = min(max(balance, -1), 1)
        // 每個 AudioWorker snapshot（音量拖動時最多每秒 20 個）都會走到
        // 這裡；內容沒變就別對帳——裝置清單或引擎狀態變動各有自己的
        // 對帳入口（audioDevicesChanged、reconcileSessions）
        guard deviceUID != deviceTarget || gain != deviceGain
            || muted != deviceMuted || eq != deviceEQ || balance != deviceBalance
            || effects != deviceEffects else { return }
        deviceTarget = deviceUID
        deviceGain = gain
        deviceMuted = muted
        deviceEQ = eq
        deviceBalance = balance
        deviceEffects = effects
        log.notice("裝置級處理：target=\(deviceUID ?? "無") gain=\(gain) muted=\(muted) eq=\(eq != nil) balance=\(balance) effects=\(effects.count)")
        reconcileGlobalSession()
        // per-app session 的音訊已從全域 tap 排除——裝置級處理不在這裡
        // 一併推，被接管的 App 就永遠套不到裝置 EQ／軟體音量
        for bundleID in sessions.keys { pushSessionProcessing(bundleID) }
    }

    /// 把「App 自己的調整 × 裝置級處理」推進一條 per-app session。
    ///
    /// 它的輸出裝置正是裝置級處理的目標時，EQ 與軟體音量在這裡套
    /// （相乘、單次——全域 tap 已排除這些行程，D17 的「只處理一次」
    /// 由排除清單保證）；不是目標時只套 App 自己的調整。
    private func pushSessionProcessing(_ bundleID: String) {
        guard let session = sessions[bundleID] else { return }
        let entry = settings.appAudio[bundleID]
        let onDeviceChain = sessionOutputUIDs[bundleID] == deviceTarget
        session.setGain(effectiveGain(entry, onDeviceChain: onDeviceChain))
        session.setMuted(entry.muted || (onDeviceChain && deviceMuted))
        session.setAppEQ(entry.eq) // App 層先過（B6-8）
        session.setEQ(onDeviceChain ? deviceEQ : nil)
        // 平衡與裝置 EQ 同層：被接管的 App 不該因為繞過全域 tap 就繞過平衡
        session.setBalance(onDeviceChain ? deviceBalance : 0)
        // AU 兩層（AU-2b）：App 層跟著 App 自己的設定，裝置層跟著鏈
        session.setAppEffects(loadableEffects(entry.effects))
        session.setDeviceEffects(onDeviceChain ? loadableEffects(deviceEffects) : [])
    }

    /// 隔離名單過濾（DESIGN §1.1）：被隔離的格不自動載入，
    /// 解除隔離是使用者的明確動作。
    private func loadableEffects(_ entries: [AUEffectEntry]) -> [AUEffectEntry] {
        entries.filter {
            $0.enabled && EffectQuarantine.mayLoad($0.component, quarantined: settings.effectQuarantine)
        }
    }

    // MARK: - 效果鏈的 UI 表面（AU-3）

    /// 裝置層某格目前的活實例（generic 參數面板編輯它）。優先全域
    /// session；沒有就找在裝置鏈上的 per-app session——同一格在多條
    /// session 各有一個實例（DESIGN §1.3），編輯其一、存檔後由 ClassInfo
    /// 就地同步到其餘。
    func liveDeviceEffectUnit(id: UUID) -> AudioUnit? {
        if let unit = globalSession?.effectUnit(layer: .device, id: id) { return unit }
        for (bundleID, session) in sessions where sessionOutputUIDs[bundleID] == deviceTarget {
            if let unit = session.effectUnit(layer: .device, id: id) { return unit }
        }
        return nil
    }

    /// App 層某格目前的活實例。
    func liveAppEffectUnit(bundleID: String, id: UUID) -> AudioUnit? {
        sessions[bundleID]?.effectUnit(layer: .app, id: id)
    }

    /// 建鏈失敗的誠實說明（外掛不在、實例化失敗）。裝置層取全域 session
    /// 的；App 層取該 App session 的。
    func deviceEffectFailures() -> [String] {
        globalSession?.effectFailures ?? []
    }

    func appEffectFailures(bundleID: String) -> [String] {
        sessions[bundleID]?.effectFailures ?? []
    }

    /// 隔離名單開關（「再試一次」＝解除隔離）。隔離名單不在 session 推送
    /// 的 dedupe 輸入裡，改完要整輪重推才會生效。
    func setQuarantined(_ quarantined: Bool, key: String) {
        var set = settings.effectQuarantine
        if quarantined { set.insert(key) } else { set.remove(key) }
        guard set != settings.effectQuarantine else { return }
        settings.effectQuarantine = set
        for bundleID in sessions.keys { pushSessionProcessing(bundleID) }
        pushDeviceProcessing()
    }

    func isQuarantined(_ component: AUEffectComponent) -> Bool {
        settings.effectQuarantine.contains(component.key)
    }

    /// 隔離閂接線：session 實例化外掛前後回呼，寫進 SettingsStore 的
    /// pendingLoad（崩潰後由啟動收養流程判定加害者）。
    private func wireEffectLatch(_ session: any TapSession) {
        session.effectLatch = { [weak self] key in
            self?.settings.effectPendingLoad = key
        }
    }

    /// 「App 增益 × 裝置級軟體音量」的組合公式——唯一定義點。
    /// 即時推送（`pushSessionProcessing`）與建立時的 `initialGain`
    ///（`reconcileSessions`）都走這裡；兩處各算一份的話，公式一改
    /// 就會回到「建立瞬間先響一段錯的音量再滑過去」那類 bug。
    private func effectiveGain(_ entry: AppAudioSetting, onDeviceChain: Bool) -> Float {
        onDeviceChain ? entry.gain * deviceGain : entry.gain
    }

    /// per-app session 換人、裝置換人、權限狀態改變後都要重算。
    ///
    /// 排除清單是**每一路音訊只處理一次**的執行點（DESIGN §2.2）：
    /// 已被 per-app tap 捕獲的行程要從全域 tap 排除，Chorus 自己更要
    /// （否則我們寫回的音訊會被自己抓走＝回授）。
    /// `knownAvailable`：呼叫端剛列過的裝置清單。列舉會對每個裝置做
    /// stream 配置的 HAL 讀取，`reconcileSessions` 已經列過就別再列一輪。
    private func reconcileGlobalSession(knownAvailable: [String]? = nil) {
        // 先看便宜的條件——taps 沒開（state ≠ active）或沒有裝置級處理
        // 時**完全不碰 HAL**。這條路每個 AudioWorker snapshot 都會走到，
        // 沒開 taps 的使用者不該為它付每秒數十次的裝置列舉。
        guard state == .active, let target = deviceTarget else {
            log.debug("global session 不成立：state=\(String(describing: self.state)) target=\(self.deviceTarget ?? "nil")")
            if globalSession != nil {
                log.notice("global session 收掉：state=\(String(describing: self.state)) target=\(self.deviceTarget ?? "無")")
            }
            stopGlobalSession()
            globalError = nil // 不再需要全域 session，舊錯誤跟著清
            refreshErrorDisplay()
            return
        }
        let available = knownAvailable ?? backend.outputDeviceUIDs()
        guard available.contains(target) else {
            log.debug("global session 不成立：target=\(target) 不在裝置清單")
            if globalSession != nil {
                log.notice("global session 收掉：target=\(target) 不在裝置清單")
            }
            stopGlobalSession()
            globalError = nil
            refreshErrorDisplay()
            return
        }
        // 排除兩類：已被 per-app tap 捕獲的（單次處理），以及使用者的
        // 排除清單（完全不碰）。後者的 App 沒在跑就查不到行程——沒關係，
        // 它一啟動 onProcessesChanged 就會帶著新行程走回這裡重建。
        var excluded = registry.processObjectIDs(
            bundleIDs: Set(sessions.keys).union(settings.excludedApps)
        )
        if let own = registry.ownProcessObjectID { excluded.append(own) }

        // 排除清單綁在 tap 建立時，改不了——內容變了只能收舊建新
        if globalSession != nil, globalOutputUID == target, globalExclusions == excluded {
            pushDeviceProcessing()
            return
        }
        stopGlobalSession()
        do {
            globalSession = try backend.startGlobalVolumeSession(
                outputDeviceUID: target,
                excludingProcessObjects: excluded,
                initialGain: deviceGain
            )
            if let globalSession { wireEffectLatch(globalSession) }
            globalOutputUID = target
            globalExclusions = excluded
            deviceTapUID = target
            globalSession?.onDeviceReconfigured = { [weak self] in
                guard let self, self.globalSession != nil else { return }
                self.log.notice("global session 的裝置重新配置 → \(self.rebuildDelay.components.seconds)s 後重建")
                self.stopGlobalSession()
                self.scheduleRebuild(after: self.rebuildDelay)
            }
            pushDeviceProcessing()
            rebuildRetries = 0
            globalError = nil
            log.notice("global session 建立：target=\(target) 排除 \(excluded.count) 個行程")
        } catch {
            log.error("global session 失敗（第 \(self.rebuildRetries + 1) 次）：target=\(target) \(String(describing: error))")
            stopGlobalSession()
            globalError = "裝置級處理啟動失敗：\(error)"
            scheduleRetry()
        }
        refreshErrorDisplay()
    }

    /// per-app 的 notice 與全域 session 的錯誤分開存——之前共用一個
    /// `lastTapError`，per-app 對帳每輪把它重設，全域的錯誤活不過一輪，
    /// 選單上永遠看不到（2026-08-30 實機除錯的教訓）。
    @ObservationIgnored private var sessionNotice: String?
    @ObservationIgnored private var globalError: String?
    private func refreshErrorDisplay() {
        lastTapError = sessionNotice ?? globalError
    }

    /// 延遲工作的唯一排程點（`rebuildTask` 的取消契約在這裡）。連續事件
    /// 互相取消，只在最後一次事件的 delay 之後跑一趟——切一輪降噪模式
    /// 只重建一次。預設動作是重新對帳（per-app ＋ 裝置級一起）；
    /// failed／denied 的重探測走同一條，只換動作。
    private func scheduleRebuild(
        after delay: Duration,
        action: @escaping @MainActor (TapEngine) -> Void = { $0.reconcileSessions() }
    ) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            action(self)
        }
    }

    /// 建立失敗重試的節奏與上限。沒有重試的話，切降噪模式的空窗撞掉
    /// 一次重建，EQ 就從此靜靜死掉（anc-log 實測：session 消失且再也
    /// 沒回來）。超過上限就停手——真的壞掉時錯誤留在 lastTapError，
    /// 等下一個自然事件。
    private static let retryDelay: Duration = .seconds(2)
    private static let maxRetries = 5

    private func scheduleRetry() {
        guard rebuildRetries < Self.maxRetries else { return }
        rebuildRetries += 1
        scheduleRebuild(after: Self.retryDelay)
    }

    private func pushDeviceProcessing() {
        globalSession?.setGain(deviceGain)
        globalSession?.setMuted(deviceMuted)
        globalSession?.setEQ(deviceEQ)
        globalSession?.setBalance(deviceBalance)
        globalSession?.setDeviceEffects(loadableEffects(deviceEffects))
    }

    private func stopGlobalSession() {
        globalSession?.stop()
        globalSession = nil
        globalOutputUID = nil
        globalExclusions = []
        deviceTapUID = nil
    }

    // MARK: - session 對帳

    /// 讓進行中的 session 與設定一致。**這是「哪些 App 有 tap」的唯一答案。**
    ///
    /// 每次設定變更、轉 active、輸出裝置變動後都跑一次。冪等——
    /// 已經對上、而且建在正確裝置上的 App 不會被收掉重建
    /// （重建會有一次可聽見的中斷）。
    private func reconcileSessions() {
        guard state == .active else {
            // 尚未取得權限：先不建 tap，設定照留。轉 active 時會再對一次帳
            return
        }
        // needsTap 而不是 adjustedBundleIDs：存了關著的 per-app EQ
        // 不代表要接管那個 App 的音訊（B6-8 起兩者分開）。
        // 排除清單再減一層：被排除的 App 即使有調整也不建 tap
        //（調整保留，取消排除即恢復）。
        let desired = Set(settings.appAudio.bundleIDsNeedingTap)
            .subtracting(settings.excludedApps)
        // Array(...)：下面會改 sessions，不要邊走邊改字典的鍵視圖
        for bundleID in Array(sessions.keys) where !desired.contains(bundleID) {
            stopSession(bundleID)
        }

        // 每次對帳重新算一次說明，不留上一輪的殘影
        var notice: String?
        var hadSessionFailure = false
        let available = Set(backend.outputDeviceUIDs())

        for bundleID in desired.sorted() {
            let entry = settings.appAudio[bundleID]
            let outputUID: String?
            if let routed = entry.outputDeviceUID {
                if available.contains(routed) {
                    outputUID = routed
                } else {
                    // 指定的裝置不在（耳機拔了）→ 退回預設但**不動設定**：
                    // 插回去時 audioDevicesChanged 會把它接回原本的目標
                    outputUID = backend.defaultOutputDeviceUID()
                    notice = "「\(bundleID)」指定的輸出裝置目前不在，暫時改用系統預設"
                }
            } else {
                outputUID = backend.defaultOutputDeviceUID()
            }
            guard let outputUID else {
                notice = "找不到輸出裝置，無法接管 \(bundleID)"
                continue
            }
            // aggregate 的 sub-device 綁在建立時、改不了——換裝置只能收舊建新
            if let actual = sessionOutputUIDs[bundleID], actual != outputUID {
                stopSession(bundleID)
            }
            // 新成員（helper）出現＝現有描述抓不到它的聲音，非重建不可；
            // 成員消失不重建——描述留著，App 重啟由系統重綁
            let members = Set(registry.memberBundleIDs(bundleID: bundleID))
            if let covered = sessionMemberBundles[bundleID], !members.isSubset(of: covered) {
                stopSession(bundleID)
            }
            if sessions[bundleID] == nil {
                do {
                    // initialGain 也要是有效值（含裝置級軟體音量）——
                    // 否則建立瞬間會先響一段只套 App 增益的音量再滑下去
                    sessions[bundleID] = try backend.startPlaythroughSession(
                        bundleID: bundleID,
                        memberBundleIDs: Array(members).sorted(),
                        outputDeviceUID: outputUID,
                        initialGain: effectiveGain(entry, onDeviceChain: outputUID == deviceTarget)
                    )
                    sessions[bundleID].map { wireEffectLatch($0) }
                    sessionOutputUIDs[bundleID] = outputUID
                    sessionMemberBundles[bundleID] = members
                    log.notice("per-app session 建立：\(bundleID) → \(outputUID) 成員 \(members.count) 個")
                    // 裝置中途改取樣率（藍牙耳機切降噪）→ 這條 session 的
                    // aggregate 格式已經過期。立刻收掉（別讓過期格式繼續出
                    // 雜音），但**延遲重建**——鏈路還在重新協商時建 aggregate
                    // 幾乎必失敗（AirPods 實測，2026-08-30）
                    sessions[bundleID]?.onDeviceReconfigured = { [weak self] in
                        guard let self, self.sessions[bundleID] != nil else { return }
                        self.log.notice("per-app session 的裝置重新配置：\(bundleID) → 收掉、\(self.rebuildDelay.components.seconds)s 後重建")
                        self.stopSession(bundleID)
                        self.scheduleRebuild(after: self.rebuildDelay)
                    }
                } catch {
                    // 單一 App 失敗不拖垮引擎：記錄並繼續，其他 session 與
                    // 裝置音量／亮度／同步完全不受影響（DESIGN §6 降級表）
                    log.error("per-app session 失敗：\(bundleID) → \(outputUID) \(String(describing: error))")
                    notice = "無法接管 \(bundleID)：\(error)"
                    hadSessionFailure = true
                    scheduleRetry()
                    continue
                }
            }
            pushSessionProcessing(bundleID)
        }
        // @Observable 的同值寫入也會觸發 UI 失效——組成沒變就不動它
        let nowTapped = sessions.keys.sorted()
        if tappedBundles != nowTapped { tappedBundles = nowTapped }
        sessionNotice = notice
        // per-app 的組成變了 → 全域 tap 的排除清單也要跟著變，
        // 否則同一路音訊會被處理兩次（reconcileGlobalSession 末尾會
        // 一併更新 lastTapError 的顯示）。裝置清單沿用上面剛列過的那份
        reconcileGlobalSession(knownAvailable: Array(available))
        // 這一輪全部就位 → 重試預算歸零。原本只有全域 session 成功會歸零，
        // per-app 的瞬時失敗（每次藍牙重協商都可能吃一次）會**累計**耗盡
        // 預算，之後的失敗再也沒有定時重試——「EQ 靜靜死掉」的慢速版。
        // 全域建立失敗時不歸零（globalSession 會是 nil），上限照常擋住
        // 持續壞掉的無限重試。
        if !hadSessionFailure, deviceTarget == nil || globalSession != nil {
            rebuildRetries = 0
        }
    }

    /// 某個 App 的 session 目前實際建在哪個裝置上（`nil` ＝ 沒有 session）。
    func activeOutputUID(bundleID: String) -> String? {
        sessions[bundleID] == nil ? nil : sessionOutputUIDs[bundleID]
    }

    private func stopSession(_ bundleID: String) {
        if sessions[bundleID] != nil {
            log.notice("per-app session 收掉：\(bundleID)（原本 → \(sessionOutputUIDs[bundleID] ?? "?")）")
        }
        sessions.removeValue(forKey: bundleID)?.stop()
        sessionOutputUIDs.removeValue(forKey: bundleID)
        sessionMemberBundles.removeValue(forKey: bundleID)
    }

    // MARK: - 探測與健康判讀

    /// `afterDeviceEvent`：這次探測是被裝置事件觸發的（插拔、重協商）。
    /// 鏈路可能還沒穩——起步就給 monitor 一段 hold，否則重探測撞上
    /// 空隙的尾巴會立刻再 latch 一次 denied。
    private func beginProbe(afterDeviceEvent: Bool = false) {
        shutdownSessions()
        monitor.reset()
        if afterDeviceEvent { monitor.noteDeviceChanged() }
        lastProbeStats = TapSessionStats()
        probeStats = TapSessionStats()
        registry.refresh()
        guard let outputUID = backend.defaultOutputDeviceUID() else {
            state = .failed("找不到預設輸出裝置")
            return
        }
        do {
            let excluded = registry.ownProcessObjectID.map { [$0] } ?? []
            probeSession = try backend.startProbeSession(
                outputDeviceUID: outputUID, excludingProcessObjects: excluded
            )
            state = .probing
            // 探測期間裝置換了格式（藍牙耳機切降噪／通透）：aggregate 的格式
            // 綁在建立時，不重建輕則卡在無聲、重則整輪誤判成權限被拒。
            // 只標 hold 不夠——格式過期的 probe 等 hold 過完照樣全零。
            probeSession?.onDeviceReconfigured = { [weak self] in
                guard let self, self.state == .probing else { return }
                self.log.notice("probe 的裝置重新配置 → \(self.rebuildDelay.components.seconds)s 後重新探測")
                self.stopProbe()
                self.scheduleRebuild(after: self.rebuildDelay) { engine in
                    guard engine.state == .probing else { return }
                    engine.beginProbe(afterDeviceEvent: true)
                }
            }
            startTicking()
        } catch {
            state = .failed("探測啟動失敗：\(error)")
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.healthTick()
                if self.state != .probing { return }
            }
        }
    }

    /// 每秒一次：把統計差分餵給 TapHealthMonitor。
    /// internal 而非 private——單元測試直接呼叫，不用等計時器。
    func healthTick() {
        guard state == .probing, let probeSession else { return }
        registry.refresh()
        let current = probeSession.stats
        probeStats = current
        let delta = current - lastProbeStats
        lastProbeStats = current
        let verdict = monitor.record(TapHealthMonitor.Window(
            callbacks: delta.callbacks,
            nonZeroCallbacks: delta.nonZeroCallbacks,
            anySourceAudible: registry.anyOtherProcessAudible
        ))
        switch verdict {
        case .healthy:
            stopProbe()
            state = .active
            // 權限到手 → 把上次的 per-app 設定套回去（App 重啟自動恢復）
            reconcileSessions()
        case .permissionDenied:
            stopProbe()
            state = .denied
        case .undetermined:
            break
        }
    }

    // MARK: - 裝置變更與收尾

    /// 預設輸出換了。跟隨預設的 session 會在對帳時因為「實際裝置 ≠ 目標
    /// 裝置」被收舊建新；**明確指定路由的不動**——使用者選了「這個 App
    /// 固定走耳機」，換系統預設不該把它拉回來。
    private func defaultOutputChanged() {
        // 探測中換了預設輸出：probe 建在舊裝置上，聲音已經走新裝置——
        // 舊 tap 從此全零，而來源仍在發聲，正是誤判成權限被拒的形狀。
        // （`audioDevicesChanged` 只在裝置**清單**變動時才叫，接不到這條。）
        // 只 hold 不夠：吸著過期裝置的 probe 永遠等不到非零，得重建。
        if state == .probing {
            log.notice("探測中預設輸出變更 → \(self.rebuildDelay.components.seconds)s 後重新探測")
            stopProbe()
            scheduleRebuild(after: rebuildDelay) { engine in
                guard engine.state == .probing else { return }
                engine.beginProbe(afterDeviceEvent: true)
            }
            return
        }
        reconcileSessions()
    }

    private func stopProbe() {
        probeSession?.stop()
        probeSession = nil
        tickTask?.cancel()
        tickTask = nil
    }

    private func shutdownSessions() {
        rebuildTask?.cancel()
        rebuildTask = nil
        rebuildRetries = 0
        stopProbe()
        stopGlobalSession()
        for (_, session) in sessions { session.stop() }
        sessions = [:]
        sessionOutputUIDs = [:]
        sessionMemberBundles = [:]
        tappedBundles = []
        sessionNotice = nil
        globalError = nil
        lastTapError = nil
    }
}
