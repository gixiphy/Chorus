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
        canSetVolume || bridgedDisplayID != nil
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
