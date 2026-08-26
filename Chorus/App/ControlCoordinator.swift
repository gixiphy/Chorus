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

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private weak var sessionManager: SyncSessionManager?
    @ObservationIgnored private weak var displayManager: DisplayManager?
    @ObservationIgnored private weak var audioManager: AudioDeviceManager?

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
        displayManager.coordinator = self
        audioManager.coordinator = self
    }

    // MARK: - 本地變更（UI 或硬體事件）

    /// 任一顯示器經 UI／鍵盤亮度鍵變更亮度 → 廣播語意層 brightness。
    func localBrightnessChanged(_ value: Double) {
        broadcastLocalChange(key: .brightness(displayUUID: nil), value: value)
    }

    /// 預設輸出裝置音量變更（UI／媒體鍵／其他 App）。
    func localVolumeChanged(_ value: Double) {
        broadcastLocalChange(key: .volume(deviceUID: nil), value: value)
    }

    func localMuteChanged(_ muted: Bool) {
        broadcastLocalChange(key: .mute(deviceUID: nil), value: muted ? 1 : 0)
    }

    // MARK: - 遙控（對特定 peer 下指令）

    func sendRemoteCommand(to peerID: String, key: ControlKey, value: Double) {
        sessionManager?.send(Envelope(msg: .command(Command(key: key, value: value))), to: peerID)
    }

    // MARK: - 遠端訊息

    private func handleEnvelope(peerID: String, _ envelope: Envelope) {
        let now = Self.wallNowMicros()
        switch envelope.msg {
        case let .stateUpdate(update):
            apply(engine.receive(update, wallNowMicros: now))
        case let .fullState(full):
            apply(engine.receiveFullState(full, wallNowMicros: now))
        case let .command(command):
            executeCommand(command)
        case .hello, .ping, .pong:
            break
        }
    }

    private func sessionEstablished(_ peerID: String) {
        let snapshot = engine.fullStateSnapshot()
        guard !snapshot.entries.isEmpty else { return }
        sessionManager?.send(Envelope(msg: .fullState(snapshot)), to: peerID)
    }

    /// 遙控指令：套用到本機，並以自己為 origin 廣播結果（其他 peer 跟著收斂）。
    private func executeCommand(_ command: Command) {
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
        }
    }

    private static func wallNowMicros() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000)
    }

    private static func wallNowMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}
