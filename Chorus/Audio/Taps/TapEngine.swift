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
    @ObservationIgnored private let log = Logger(subsystem: "com.hermes.Chorus", category: "taps")

    private(set) var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            log.notice("state: \(String(describing: oldValue), privacy: .public) → \(String(describing: self.state), privacy: .public)")
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
        update(bundleID: bundleID) { $0.gain = AppAudioSetting.clampGain(gain) }
    }

    func setMuted(_ muted: Bool, bundleID: String) {
        update(bundleID: bundleID) { $0.muted = muted }
    }

    func toggleMuted(bundleID: String) {
        setMuted(!setting(for: bundleID).muted, bundleID: bundleID)
    }

    /// 指定輸出裝置；`nil` ＝跟隨系統預設（B6-3）。
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

    private func update(bundleID: String, _ mutate: (inout AppAudioSetting) -> Void) {
        var all = settings.appAudio
        var entry = all[bundleID]
        mutate(&entry)
        all[bundleID] = entry
        settings.appAudio = all
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
            rebuildTask?.cancel()
            rebuildTask = Task { [weak self] in
                try? await Task.sleep(for: self?.rebuildDelay ?? .seconds(1.5))
                guard let self, !Task.isCancelled else { return }
                if case .active = self.state { return } // 期間已經活了就別打斷
                self.beginProbe()
            }
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
        deviceUID: String?, gain: Float, muted: Bool, eq: EQSettings?
    ) {
        deviceTarget = deviceUID
        deviceGain = AppAudioSetting.clampGain(gain)
        deviceMuted = muted
        deviceEQ = eq
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
        session.setGain(onDeviceChain ? entry.gain * deviceGain : entry.gain)
        session.setMuted(entry.muted || (onDeviceChain && deviceMuted))
        session.setEQ(onDeviceChain ? deviceEQ : nil)
    }

    /// per-app session 換人、裝置換人、權限狀態改變後都要重算。
    ///
    /// 排除清單是**每一路音訊只處理一次**的執行點（DESIGN §2.2）：
    /// 已被 per-app tap 捕獲的行程要從全域 tap 排除，Chorus 自己更要
    /// （否則我們寫回的音訊會被自己抓走＝回授）。
    private func reconcileGlobalSession() {
        guard state == .active, let target = deviceTarget,
              backend.outputDeviceUIDs().contains(target)
        else {
            stopGlobalSession()
            globalError = nil // 不再需要全域 session，舊錯誤跟著清
            refreshErrorDisplay()
            return
        }
        var excluded = registry.processObjectIDs(bundleIDs: Set(sessions.keys))
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
            globalOutputUID = target
            globalExclusions = excluded
            deviceTapUID = target
            globalSession?.onDeviceReconfigured = { [weak self] in
                guard let self, self.globalSession != nil else { return }
                self.log.notice("global session 的裝置重新配置 → \(self.rebuildDelay.components.seconds, privacy: .public)s 後重建")
                self.stopGlobalSession()
                self.scheduleRebuild(after: self.rebuildDelay)
            }
            pushDeviceProcessing()
            rebuildRetries = 0
            globalError = nil
            log.notice("global session 建立：target=\(target, privacy: .public) 排除 \(excluded.count, privacy: .public) 個行程")
        } catch {
            log.error("global session 失敗（第 \(self.rebuildRetries + 1, privacy: .public) 次）：target=\(target, privacy: .public) \(String(describing: error), privacy: .public)")
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

    /// 延遲後重新對帳（per-app ＋ 裝置級一起）。連續事件互相取消，
    /// 只在最後一次事件的 delay 之後跑一趟——切一輪降噪模式只重建一次。
    private func scheduleRebuild(after delay: Duration) {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.reconcileSessions()
        }
    }

    /// 建立失敗後的重試。沒有它，切降噪模式的空窗撞掉一次重建，
    /// EQ 就從此靜靜死掉（anc-log 實測：session 消失且再也沒回來）。
    /// 上限 5 次——真的壞掉時錯誤留在 lastTapError，等下一個自然事件。
    private func scheduleRetry() {
        guard rebuildRetries < 5 else { return }
        rebuildRetries += 1
        scheduleRebuild(after: .seconds(2))
    }

    private func pushDeviceProcessing() {
        globalSession?.setGain(deviceGain)
        globalSession?.setMuted(deviceMuted)
        globalSession?.setEQ(deviceEQ)
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
        let desired = Set(settings.appAudio.adjustedBundleIDs)
        // Array(...)：下面會改 sessions，不要邊走邊改字典的鍵視圖
        for bundleID in Array(sessions.keys) where !desired.contains(bundleID) {
            stopSession(bundleID)
        }

        // 每次對帳重新算一次說明，不留上一輪的殘影
        var notice: String?
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
                    let onDeviceChain = outputUID == deviceTarget
                    sessions[bundleID] = try backend.startPlaythroughSession(
                        bundleID: bundleID,
                        memberBundleIDs: Array(members).sorted(),
                        outputDeviceUID: outputUID,
                        initialGain: onDeviceChain ? entry.gain * deviceGain : entry.gain
                    )
                    sessionOutputUIDs[bundleID] = outputUID
                    sessionMemberBundles[bundleID] = members
                    // 裝置中途改取樣率（藍牙耳機切降噪）→ 這條 session 的
                    // aggregate 格式已經過期。立刻收掉（別讓過期格式繼續出
                    // 雜音），但**延遲重建**——鏈路還在重新協商時建 aggregate
                    // 幾乎必失敗（AirPods 實測，2026-08-30）
                    sessions[bundleID]?.onDeviceReconfigured = { [weak self] in
                        guard let self, self.sessions[bundleID] != nil else { return }
                        self.stopSession(bundleID)
                        self.scheduleRebuild(after: self.rebuildDelay)
                    }
                } catch {
                    // 單一 App 失敗不拖垮引擎：記錄並繼續，其他 session 與
                    // 裝置音量／亮度／同步完全不受影響（DESIGN §6 降級表）
                    log.error("per-app session 失敗：\(bundleID, privacy: .public) → \(outputUID, privacy: .public) \(String(describing: error), privacy: .public)")
                    notice = "無法接管 \(bundleID)：\(error)"
                    scheduleRetry()
                    continue
                }
            }
            pushSessionProcessing(bundleID)
        }
        tappedBundles = sessions.keys.sorted()
        sessionNotice = notice
        // per-app 的組成變了 → 全域 tap 的排除清單也要跟著變，
        // 否則同一路音訊會被處理兩次（reconcileGlobalSession 末尾會
        // 一併更新 lastTapError 的顯示）
        reconcileGlobalSession()
    }

    /// 某個 App 的 session 目前實際建在哪個裝置上（`nil` ＝ 沒有 session）。
    func activeOutputUID(bundleID: String) -> String? {
        sessions[bundleID] == nil ? nil : sessionOutputUIDs[bundleID]
    }

    private func stopSession(_ bundleID: String) {
        sessions.removeValue(forKey: bundleID)?.stop()
        sessionOutputUIDs.removeValue(forKey: bundleID)
        sessionMemberBundles.removeValue(forKey: bundleID)
    }

    // MARK: - 探測與健康判讀

    private func beginProbe() {
        shutdownSessions()
        monitor.reset()
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
