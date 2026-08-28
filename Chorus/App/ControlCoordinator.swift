import ChorusCore
import Foundation
import Observation

/// 同步樞紐：本地變更 → 硬體 + 節流廣播；遠端更新 → 硬體（**永不**再廣播）。
///
/// 防迴圈第三層（expectedValue echo 抑制）分散在 DisplayManager 的 poller
/// 與 AudioDeviceManager 的 recentLocalSets —— 遠端套用走 applySynced* 路徑，
/// 不會觸發 local-change 回呼。
@MainActor
@Observable
final class ControlCoordinator {
    @ObservationIgnored private var engine: SyncEngineCore
    @ObservationIgnored private var throttle = Throttle(intervalMillis: 50)
    @ObservationIgnored private var pendingValues: [ControlKey: Double] = [:]
    @ObservationIgnored private var pendingTasks: [ControlKey: Task<Void, Never>] = [:]
    /// 待送出的現值回報（200ms 合併成一則）。
    @ObservationIgnored private var pendingReports: [ControlKey: Double] = [:]
    @ObservationIgnored private var reportTask: Task<Void, Never>?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private weak var sessionManager: SyncSessionManager?
    @ObservationIgnored private weak var displayManager: DisplayManager?
    @ObservationIgnored private weak var audioManager: AudioDeviceManager?
    @ObservationIgnored private weak var autoController: AutoBrightnessController?
    @ObservationIgnored private weak var keepAwake: KeepAwakeController?
    /// 逐 App 音量遙控的收件人（B6-6）。
    @ObservationIgnored weak var tapEngine: TapEngine?
    /// 自動化事件流（SSE／CLI listen）。本機任何來源的變更都往這裡發一份。
    @ObservationIgnored weak var automationEvents: AutomationEventHub?

    init(
        localPeerID: String,
        settings: SettingsStore,
        sessionManager: SyncSessionManager,
        displayManager: DisplayManager,
        audioManager: AudioDeviceManager
    ) {
        engine = SyncEngineCore(localPeerID: localPeerID)
        self.settings = settings
        self.sessionManager = sessionManager
        self.displayManager = displayManager
        self.audioManager = audioManager

        sessionManager.envelopeHandler = { [weak self] peerID, envelope in
            self?.handleEnvelope(peerID: peerID, envelope)
        }
        sessionManager.sessionEstablishedHandler = { [weak self] peerID in
            self?.sessionEstablished(peerID)
        }
        sessionManager.sessionClosedHandler = { [weak self] peerID in
            self?.autoController?.peerDisconnected(peerID)
        }
        displayManager.coordinator = self
        audioManager.coordinator = self
    }

    /// AppState 組裝時注入防睡眠控制器（`.keepAwake` 遙控指令的收件人）。
    func attachKeepAwake(_ controller: KeepAwakeController) {
        keepAwake = controller
    }

    /// AppState 組裝時注入自動亮度控制器，並接上環境光回報的廣播管道。
    func attachAutoController(_ controller: AutoBrightnessController) {
        autoController = controller
        controller.broadcastHandler = { [weak self] report in
            self?.sessionManager?.broadcast(Envelope(msg: .ambientReport(report)))
        }
    }

    // MARK: - 本地變更（UI 或硬體事件）

    /// 任一顯示器經 UI／鍵盤亮度鍵變更亮度 → 廣播語意層 brightness。
    func localBrightnessChanged(_ value: Double) {
        let key = ControlKey.brightness(displayUUID: nil)
        automationEvents?.publishControlChange(key: key, value: value)
        reportLocalState(key: key, value: value)
        broadcastLocalChange(key: key, value: value)
    }

    /// 預設輸出裝置音量變更（UI／媒體鍵／其他 App）。
    func localVolumeChanged(_ value: Double) {
        let key = ControlKey.volume(deviceUID: nil)
        automationEvents?.publishControlChange(key: key, value: value)
        reportLocalState(key: key, value: value)
        broadcastLocalChange(key: key, value: value)
    }

    func localMuteChanged(_ muted: Bool) {
        let key = ControlKey.mute(deviceUID: nil)
        automationEvents?.publishControlChange(key: key, value: muted ? 1 : 0)
        reportLocalState(key: key, value: muted ? 1 : 0)
        broadcastLocalChange(key: key, value: muted ? 1 : 0)
    }

    // MARK: - 遙控（對特定 peer 下指令）

    func sendRemoteCommand(to peerID: String, key: ControlKey, value: Double) {
        sessionManager?.send(Envelope(msg: .command(Command(key: key, value: value))), to: peerID)
        recordPeerKnown(peerID: peerID, key: key, value: value)
    }

    /// 記住 peer 最後已知的語意層數值（遙控滑桿初始位置用；跨重啟保留）。
    private func recordPeerKnown(peerID: String, key: ControlKey, value: Double) {
        let field: String
        switch key {
        case .brightness(nil): field = "brightness"
        case .volume(nil): field = "volume"
        case .mute(nil): field = "muted"
        default: return
        }
        var known = settings.peerKnownControls[peerID] ?? [:]
        guard known[field] != value else { return }
        known[field] = value
        settings.peerKnownControls[peerID] = known
    }

    // MARK: - 遠端訊息

    private func handleEnvelope(peerID: String, _ envelope: Envelope) {
        let now = Self.wallNowMicros()
        switch envelope.msg {
        case let .stateUpdate(update):
            recordPeerKnown(peerID: peerID, key: update.key, value: update.value)
            apply(engine.receive(update, wallNowMicros: now))
        case let .fullState(full):
            for entry in full.entries {
                recordPeerKnown(peerID: peerID, key: entry.key, value: entry.value)
            }
            apply(engine.receiveFullState(full, wallNowMicros: now))
        case let .command(command):
            executeCommand(command)
        case let .ambientReport(report):
            autoController?.receiveRemoteBaseline(report)
        case let .setDeviceOffset(command):
            autoController?.setDeviceOffset(command.offset)
        case .stateQuery:
            sessionManager?.send(Envelope(msg: .stateReport(currentStateReport())), to: peerID)
        case let .stateReport(report):
            // 純資訊：只更新「對方現在是多少」，不碰硬體、不進 LWW
            for entry in report.entries {
                recordPeerKnown(peerID: peerID, key: entry.key, value: entry.value)
            }
        case .hello, .ping, .pong:
            break
        }
    }

    private func sessionEstablished(_ peerID: String) {
        let snapshot = engine.fullStateSnapshot()
        if !snapshot.entries.isEmpty {
            sessionManager?.send(Envelope(msg: .fullState(snapshot)), to: peerID)
        }
        // 本機是環境光來源時補發最新回報，讓剛連上的 follower 立即收斂
        if let report = autoController?.latestLocalReport() {
            sessionManager?.send(Envelope(msg: .ambientReport(report)), to: peerID)
        }
        // 現值回報：對方的遙控滑桿要畫在正確的位置。fullState 幫不上忙——
        // 它只含「本次啟動後改過的 key」，而且會被 LWW 當成狀態套進硬體。
        sessionManager?.send(Envelope(msg: .stateReport(currentStateReport())), to: peerID)
    }

    // MARK: - 現值回報（遙控滑桿的顯示值）

    /// 請對方回報現值。開啟選單列時呼叫——同步關掉、或對方的變更來自
    /// 自動亮度（不廣播）時，我們手上的值可能已經過期好幾天。
    func requestPeerState(from peerID: String) {
        sessionManager?.send(Envelope(msg: .stateQuery(StateQuery())), to: peerID)
    }

    /// 本機現在的語意層亮度／音量。回報用，不進 SyncEngineCore。
    private func currentStateReport() -> StateReport {
        var entries: [StateReport.Entry] = []
        if let brightness = displayManager?.displays.first?.brightness {
            entries.append(StateReport.Entry(key: .brightness(displayUUID: nil), value: brightness))
        }
        if let device = audioManager?.defaultDevice {
            entries.append(StateReport.Entry(key: .volume(deviceUID: nil), value: device.volume))
            entries.append(StateReport.Entry(key: .mute(deviceUID: nil), value: device.muted ? 1 : 0))
        }
        return StateReport(entries: entries)
    }

    /// 本機變更 → 廣播現值。與 stateUpdate 分兩條：**同步開關關掉時也要送**
    /// （對方的遙控滑桿仍該顯示我們的實際值），而且對方收到永不套用到硬體。
    /// 200ms 合併：拖曳滑桿一秒鐘會產生數十次變更。
    private func reportLocalState(key: ControlKey, value: Double) {
        pendingReports[key] = value
        guard reportTask == nil else { return }
        reportTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            self?.flushReports()
        }
    }

    private func flushReports() {
        reportTask = nil
        let entries = pendingReports.map { StateReport.Entry(key: $0.key, value: $0.value) }
        pendingReports.removeAll()
        guard !entries.isEmpty else { return }
        sessionManager?.broadcast(Envelope(msg: .stateReport(StateReport(entries: entries))))
    }

    /// 配置圖：調整某個 peer 的整機亮度差異值。
    func sendDeviceOffset(to peerID: String, offset: Double) {
        sessionManager?.send(Envelope(msg: .setDeviceOffset(DeviceOffsetCommand(offset: offset))), to: peerID)
    }

    /// 遙控指令：套用到本機，並以自己為 origin 廣播結果（其他 peer 跟著收斂）。
    /// 語意層亮度另走命令路徑：auto 受管顯示器要學差異值而非被同步抑制吞掉，
    /// 是否廣播由 DisplayManager 依受管狀態決定。
    private func executeCommand(_ command: Command) {
        if case .brightness(nil) = command.key {
            displayManager?.applyCommandBrightness(command.value)
            return
        }
        applyToHardware(key: command.key, value: command.value)
        broadcastLocalChange(key: command.key, value: command.value)
    }

    // MARK: - 套用與廣播

    private func apply(_ effects: [SyncEngineCore.Effect]) {
        for case let .applyToHardware(key, value) in effects {
            guard syncEnabled(for: key) else { continue }
            applyToHardware(key: key, value: value)
        }
    }

    private func applyToHardware(key: ControlKey, value: Double) {
        // 遠端套用也要進事件流——訂閱者要看到的是「這台機器發生了什麼」，
        // 不是「誰下的指令」。本機來源走 local*Changed，兩條不會重複。
        automationEvents?.publishControlChange(key: key, value: value)
        switch key {
        case .brightness(nil):
            displayManager?.applySyncedBrightness(value)
        case let .brightness(uuid?):
            displayManager?.applyBrightness(value, toUUID: uuid)
        case .volume(nil):
            audioManager?.applySyncedVolume(value)
        case let .volume(uid?):
            audioManager?.applyVolume(value, toUID: uid)
        case .mute(nil):
            audioManager?.applySyncedMute(value > 0.5)
        case let .mute(uid?):
            audioManager?.applyMute(value > 0.5, toUID: uid)
        case let .input(uuid?):
            // value 是 MCCS 輸入源代碼原值（非 0–1）
            displayManager?.applyInput(UInt16(value.rounded()), toUUID: uuid)
        case let .contrast(uuid?):
            displayManager?.applyContrast(value, toUUID: uuid)
        case .displayPower(nil):
            displayManager?.applyCommandDisplayPower(value > 0.5)
        case let .displayPower(uuid?):
            displayManager?.applyDisplayPower(value > 0.5, toUUID: uuid)
        case .keepAwake:
            // 螢幕綁定模式是本機設定，不跨機——decode 一律回計時／無限期／關閉
            keepAwake?.activate(KeepAwakePlanner.decode(value))
        case let .appVolume(bundleID):
            tapEngine?.setGain(Float(value), bundleID: bundleID)
        case let .appMute(bundleID):
            tapEngine?.setMuted(value > 0.5, bundleID: bundleID)
        case .input(nil), .contrast(nil):
            break // 語意層無意義（預留）
        }
    }

    private func broadcastLocalChange(key: ControlKey, value: Double) {
        guard syncEnabled(for: key) else { return }
        let nowMs = Self.wallNowMillis()
        switch throttle.shouldSend(key: key, nowMillis: nowMs) {
        case .sendNow:
            sendUpdate(key: key, value: value)
        case let .deferUntil(millis):
            pendingValues[key] = value
            guard pendingTasks[key] == nil else { return }
            let delay = max(millis - nowMs, 1)
            pendingTasks[key] = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                self?.flushPending(key: key)
            }
        }
    }

    private func flushPending(key: ControlKey) {
        pendingTasks[key] = nil
        guard let value = pendingValues.removeValue(forKey: key) else { return }
        throttle.didSendDeferred(key: key, nowMillis: Self.wallNowMillis())
        sendUpdate(key: key, value: value)
    }

    private func sendUpdate(key: ControlKey, value: Double) {
        let update = engine.localChange(key: key, value: value, wallNowMicros: Self.wallNowMicros())
        sessionManager?.broadcast(Envelope(msg: .stateUpdate(update)))
    }

    private func syncEnabled(for key: ControlKey) -> Bool {
        switch key {
        case .brightness: settings.syncBrightnessEnabled
        case .volume, .mute: settings.syncVolumeEnabled
        // command 專用鍵：不做狀態同步（executeCommand 仍會套用到硬體）。
        // 電源與防睡眠是動作而非可收斂的狀態——用 LWW 同步會讓兩台機器
        // 互相把對方的螢幕關掉／打開。
        case .input, .contrast, .displayPower, .keepAwake: false
        // per-app 是遙控不是鏡射（DESIGN／PLAN B6-6）：兩台機器上的
        // 「音樂 App 的音量」不是同一個東西，用 LWW 同步只會互相覆蓋
        case .appVolume, .appMute: false
        }
    }

    private static func wallNowMicros() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000)
    }

    private static func wallNowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
