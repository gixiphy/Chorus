import CoreAudio
import Foundation
import Observation

/// 輸出裝置清單與音量/mute/預設裝置控制的入口（MainActor）。
/// 實際 CoreAudio IO 在 AudioWorker 的 serial queue 上。
@MainActor
@Observable
final class AudioDeviceManager {
    private(set) var devices: [AudioDeviceModel] = []

    @ObservationIgnored private let worker = AudioWorker()
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private weak var displayManager: DisplayManager?
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored weak var coordinator: ControlCoordinator?

    /// 我們自己剛寫入的值：snapshot 回報若與其相近則不覆蓋 UI（避免拖曳中跳動）。
    @ObservationIgnored private var recentLocalSets: [String: (value: Double, at: ContinuousClock.Instant)] = [:]
    /// DDC 音量寫後驗證任務（每裝置一個，拖曳中重排程）。
    @ObservationIgnored private var bridgeVerifyTasks: [String: Task<Void, Never>] = [:]

    var defaultDevice: AudioDeviceModel? {
        devices.first(where: \.isDefault)
    }

    /// 選單列顯示的裝置：排除使用者隱藏的；預設輸出永遠顯示（避免被劫走
    /// 預設卻看不到是誰）。
    var visibleDevices: [AudioDeviceModel] {
        devices.filter { !settings.hiddenAudioDevices.contains($0.uid) || $0.isDefault }
    }

    func setHidden(_ hidden: Bool, for device: AudioDeviceModel) {
        var set = settings.hiddenAudioDevices
        if hidden { set.insert(device.uid) } else { set.remove(device.uid) }
        settings.hiddenAudioDevices = set
    }

    func isHidden(_ device: AudioDeviceModel) -> Bool {
        settings.hiddenAudioDevices.contains(device.uid)
    }

    init(settings: SettingsStore, displayManager: DisplayManager) {
        self.settings = settings
        self.displayManager = displayManager
    }

    func start() {
        worker.start()
        consumeTask = Task { [weak self] in
            guard let stream = self?.worker.snapshots else { return }
            for await snapshot in stream {
                self?.apply(snapshot)
            }
        }
    }

    // MARK: - 控制

    /// 使用者透過 UI 設定音量（預設裝置會廣播同步）。value 0–1。
    func setVolume(_ value: Double, for device: AudioDeviceModel) {
        let clamped = min(max(value, 0), 1)
        writeVolume(clamped, to: device)
        if device.isDefault {
            coordinator?.localVolumeChanged(clamped)
        }
    }

    func setMuted(_ muted: Bool, for device: AudioDeviceModel) {
        writeMute(muted, to: device)
        if device.isDefault {
            coordinator?.localMuteChanged(muted)
        }
    }

    /// 遠端同步套用到預設裝置。**不**觸發廣播。
    func applySyncedVolume(_ value: Double) {
        guard let device = defaultDevice else { return }
        writeVolume(min(max(value, 0), 1), to: device)
    }

    func applySyncedMute(_ muted: Bool) {
        guard let device = defaultDevice else { return }
        writeMute(muted, to: device)
    }

    /// 遙控指定裝置（UID 不存在時 no-op）。**不**觸發廣播。
    func applyVolume(_ value: Double, toUID uid: String) {
        guard let device = devices.first(where: { $0.uid == uid }) else { return }
        writeVolume(min(max(value, 0), 1), to: device)
    }

    func applyMute(_ muted: Bool, toUID uid: String) {
        guard let device = devices.first(where: { $0.uid == uid }) else { return }
        writeMute(muted, to: device)
    }

    private func writeVolume(_ clamped: Double, to device: AudioDeviceModel) {
        device.volume = clamped
        recentLocalSets[device.uid] = (clamped, ContinuousClock.now)
        settings.setLastVolume(clamped, for: device.uid)

        if device.canSetVolume {
            worker.setVolume(device.id, to: clamped)
        } else if let displayID = device.bridgedDisplayID {
            displayManager?.ddc.write(displayID, vcp: DDCController.VCP.volume, value: UInt16((clamped * 100).rounded()))
            scheduleBridgeVerify(device: device, displayID: displayID, expected: clamped)
        }
    }

    /// 寫後驗證：拖曳結束 1.5 秒後回讀 VCP 0x62，分辨「橋接正常」與
    /// 「螢幕不理音量指令（不支援 0x62）」——兩者在 UI 上完全看不出差別，
    /// 只有讀值能戳破。讀不到（螢幕不支援讀）視為無定論、不標記。
    private func scheduleBridgeVerify(device: AudioDeviceModel, displayID: CGDirectDisplayID, expected: Double) {
        guard let displayManager,
              let display = displayManager.displays.first(where: { $0.id == displayID }),
              !settings.disableDDCRead.contains(display.uuid) else { return }
        let uid = device.uid
        bridgeVerifyTasks[uid]?.cancel()
        bridgeVerifyTasks[uid] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            guard let result = await self.displayManager?.ddc.read(displayID, vcp: DDCController.VCP.volume),
                  result.max > 0 else { return }
            guard let model = self.devices.first(where: { $0.uid == uid }),
                  model.bridgedDisplayID == displayID else { return }
            let actual = Double(result.current) / Double(result.max)
            model.bridgeUnresponsive = abs(actual - expected) > 0.08
        }
    }

    private func writeMute(_ muted: Bool, to device: AudioDeviceModel) {
        device.muted = muted
        if device.hasMute {
            worker.setMute(device.id, muted: muted)
        } else if let displayID = device.bridgedDisplayID {
            displayManager?.ddc.write(
                displayID,
                vcp: DDCController.VCP.mute,
                value: muted ? DDCController.MuteValue.muted : DDCController.MuteValue.unmuted
            )
        }
    }

    func setAsDefault(_ device: AudioDeviceModel) {
        for model in devices {
            model.isDefault = model.id == device.id
        }
        worker.setDefaultOutputDevice(device.id)
    }

    // MARK: - Snapshot 套用

    private func apply(_ snapshot: AudioWorker.Snapshot) {
        var updated: [AudioDeviceModel] = []
        for info in snapshot.devices {
            let isDefault = info.id == snapshot.defaultDeviceID
            if let existing = devices.first(where: { $0.uid == info.uid }) {
                existing.isDefault = isDefault
                // 橋接裝置（無 CoreAudio 音量）的 snapshot 值無意義（恆為 0），
                // model 由 DDC 路徑維護——不能讓任何音訊事件把滑桿蓋成 0。
                if info.canSetVolume, !shouldPreserveLocalValue(uid: info.uid, reported: info.volume) {
                    // 非本 App 寫入造成的變更（媒體鍵、其他 App）→ 視為本地硬體事件
                    let changed = abs(existing.volume - info.volume) > 0.005
                    existing.volume = info.volume
                    if changed, isDefault {
                        coordinator?.localVolumeChanged(info.volume)
                    }
                }
                if info.hasMute, existing.muted != info.muted {
                    existing.muted = info.muted
                    if isDefault {
                        coordinator?.localMuteChanged(info.muted)
                    }
                }
                updated.append(existing)
            } else {
                let model = AudioDeviceModel(info: info, isDefault: isDefault)
                if !info.canSetVolume {
                    // HDMI/DP 裝置沒有軟體音量：試著橋接到 DDC 顯示器
                    model.bridgedDisplayID = bridgeTarget(forDeviceNamed: info.name)?.id
                    model.volume = settings.lastVolume(for: info.uid) ?? 0.3
                }
                updated.append(model)
            }
        }
        devices = updated
        refreshBridges()
        sortDevices()
    }

    /// 重算所有無軟體音量裝置的 DDC 橋接。
    /// 首次橋接常敗在時序：音訊 snapshot 比 DDC 能力探測先到，當時還沒有
    /// 任何 .ddc 顯示器可配。DisplayManager 每次 refresh 完成後回呼這裡補配；
    /// DDC 降級（gammaOnly）時也在此清掉失效的橋接。
    func refreshBridges() {
        for device in devices where !device.canSetVolume {
            let target = bridgeTarget(forDeviceNamed: device.name)
            if device.bridgedDisplayID != target?.id {
                let isNewBridge = device.bridgedDisplayID == nil
                device.bridgedDisplayID = target?.id
                if isNewBridge, let target {
                    initializeBridgedVolume(device: device, display: target)
                }
            }
        }
    }

    /// 橋接建立時讀螢幕的 VCP 0x62 現值回填滑桿（否則只能猜上次記住的值，
    /// 滑桿位置對不上硬體）。該螢幕停用 DDC 讀取時跳過。
    private func initializeBridgedVolume(device: AudioDeviceModel, display: DisplayModel) {
        guard !settings.disableDDCRead.contains(display.uuid) else { return }
        let displayID = display.id
        let uid = device.uid
        Task { [weak self] in
            guard let ddc = self?.displayManager?.ddc,
                  let result = await ddc.read(displayID, vcp: DDCController.VCP.volume),
                  result.max > 0 else { return }
            guard let self, let model = self.devices.first(where: { $0.uid == uid }),
                  model.bridgedDisplayID == displayID else { return }
            let value = Double(result.current) / Double(result.max)
            model.volume = value
            self.settings.setLastVolume(value, for: uid)
        }
    }

    /// 內建優先、其次依名稱排序。
    private func sortDevices() {
        var updated = devices
        updated.sort { lhs, rhs in
            let lhsBuiltin = lhs.transportType == kAudioDeviceTransportTypeBuiltIn
            let rhsBuiltin = rhs.transportType == kAudioDeviceTransportTypeBuiltIn
            if lhsBuiltin != rhsBuiltin { return lhsBuiltin }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        devices = updated
    }

    /// 300ms 內我們自己寫過相近值 → 保留 UI 值，避免硬體量化造成 slider 抖動。
    private func shouldPreserveLocalValue(uid: String, reported: Double) -> Bool {
        guard let recent = recentLocalSets[uid] else { return false }
        guard ContinuousClock.now - recent.at < .milliseconds(300) else {
            recentLocalSets.removeValue(forKey: uid)
            return false
        }
        return abs(recent.value - reported) < 0.05
    }

    /// 無軟體音量的裝置 → 對應的 DDC 顯示器。
    /// 名稱吻合優先；否則若只有一台 DDC 外接螢幕就用它。
    private func bridgeTarget(forDeviceNamed name: String) -> DisplayModel? {
        guard let displays = displayManager?.displays else { return nil }
        let ddcDisplays = displays.filter { $0.backend == .ddc }
        if let match = ddcDisplays.first(where: {
            $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name)
        }) {
            return match
        }
        return ddcDisplays.count == 1 ? ddcDisplays.first : nil
    }
}
