import CoreAudio
import CoreGraphics
import Foundation
import Observation

/// 單一輸出裝置的可觀察狀態。
@MainActor
@Observable
final class AudioDeviceModel: Identifiable {
    let id: AudioObjectID
    /// 跨重啟穩定的識別碼（同步協定與設定以此為 key）。
    let uid: String
    let name: String
    let transportType: UInt32
    /// CoreAudio 可直接設定音量（HDMI/DP 裝置通常為 false）。
    let canSetVolume: Bool
    let hasMute: Bool

    /// 無軟體音量時橋接到的 DDC 顯示器（nil 表示無法橋接，音量不可控）。
    var bridgedDisplayID: CGDirectDisplayID?
    /// 寫後驗證讀值發現螢幕沒有套用音量指令（可能不支援 VCP 0x62）。
    var bridgeUnresponsive = false
    /// 螢幕回報的音量值域上限（VCP 0x62 的 max；讀不到時假設 100）。
    /// 有些螢幕不是 0–100，硬寫 0–100 會被忽略或夾錯。
    var bridgeVolumeMax: UInt16 = 100

    /// 三後端矩陣的第三條正在這個裝置上生效（B6-4）：沒有硬體音量、
    /// 沒有 DDC，改由排除式全域 tap 做軟體衰減。
    /// 由 `AudioDeviceManager.refreshBridges()` 算出——**與前兩條互斥**。
    var softwareVolumeActive = false

    var volume: Double
    var muted: Bool
    var isDefault: Bool

    init(info: AudioWorker.DeviceInfo, isDefault: Bool) {
        id = info.id
        uid = info.uid
        name = info.name
        transportType = info.transportType
        canSetVolume = info.canSetVolume
        hasMute = info.hasMute
        volume = info.volume
        muted = info.muted
        self.isDefault = isDefault
    }

    var isVolumeControllable: Bool {
        canSetVolume || bridgedDisplayID != nil || softwareVolumeActive
    }

    var transportLabel: String? {
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "藍牙"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeUSB: "USB"
        default: nil
        }
    }
}
