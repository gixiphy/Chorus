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

    /// 我們自己剛寫入的值：snapshot 回報若與其相近則不覆蓋 UI（避免拖曳中跳動）。
    @ObservationIgnored private var recentLocalSets: [String: (value: Double, at: ContinuousClock.Instant)] = [:]

    var defaultDevice: AudioDeviceModel? {
        devices.first(where: \.isDefault)
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

    /// 使用者（或之後的同步引擎）設定音量。value 0–1。
    func setVolume(_ value: Double, for device: AudioDeviceModel) {
        let clamped = min(max(value, 0), 1)
        device.volume = clamped
        recentLocalSets[device.uid] = (clamped, ContinuousClock.now)
        settings.setLastVolume(clamped, for: device.uid)

        if device.canSetVolume {
            worker.setVolume(device.id, to: clamped)
        } else if let displayID = device.bridgedDisplayID {
            displayManager?.ddc.write(displayID, vcp: DDCController.VCP.volume, value: UInt16((clamped * 100).rounded()))
        }
    }

    func setMuted(_ muted: Bool, for device: AudioDeviceModel) {
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
                if !shouldPreserveLocalValue(uid: info.uid, reported: info.volume) {
                    existing.volume = info.volume
                }
                existing.muted = info.muted
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
        // 內建優先、其次依名稱排序
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
