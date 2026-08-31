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

    /// 裝置有原生左右平衡（HAL 合成的 vmbc 或 stereo pan control）。
    /// 沒有的話平衡走裝置級 tap 鏈（軟體平衡）——兩後端互斥，
    /// 由 `AudioDeviceManager.setBalance` 分流。
    let canSetBalance: Bool
    /// 左右平衡（−1…+1，0＝置中）。native 裝置以 HAL 現值為準；
    /// 軟體平衡以 `SettingsStore.deviceBalance` 為準。
    var balance: Double

    init(info: AudioWorker.DeviceInfo, isDefault: Bool) {
        id = info.id
        uid = info.uid
        name = info.name
        transportType = info.transportType
        canSetVolume = info.canSetVolume
        hasMute = info.hasMute
        volume = info.volume
        muted = info.muted
        canSetBalance = info.canSetBalance
        balance = info.balance
        self.isDefault = isDefault
    }

    var isVolumeControllable: Bool {
        canSetVolume || bridgedDisplayID != nil || softwareVolumeActive
    }

    /// 這個裝置作為轉送目標時，音量走哪條路——**唯一判準**，UI 徽章
    /// （VolumeSliderRow）與 driver 鏡射模式（AudioDeviceManager.
    /// updateVirtualMirrorMode）都從這裡讀，不各自再判一次：
    /// DDC 橋接且回應正常 → 硬體鏡射；裝置自己有原生音量 → 音量鏡射；
    /// 都沒有 → driver 端數位衰減。
    enum ForwardVolumeMode { case ddc, native, digital }
    var forwardVolumeMode: ForwardVolumeMode {
        if bridgedDisplayID != nil, !bridgeUnresponsive { return .ddc }
        if canSetVolume { return .native }
        return .digital
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
