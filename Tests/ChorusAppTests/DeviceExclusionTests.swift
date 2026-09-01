import ChorusCore
import CoreAudio
import Foundation
import Testing
@testable import Chorus

/// per-device 排除清單：Chorus 不在被排除的裝置上做任何「裝置級處理」
/// （軟體音量／EQ／左右平衡／AU 效果鏈），但音量滑桿照常運作。
///
/// 與 per-App 排除（`excludedApps`）是不同的軸——那個是「這個 App 的音訊
/// 完全不碰」，這個是「這個裝置上不插入處理」。
@MainActor
@Suite("裝置排除清單")
struct DeviceExclusionTests {
    private func makeManager() -> (AudioDeviceManager, SettingsStore) {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "device-exclusion-\(UUID().uuidString)")!)
        let displays = DisplayManager(settings: settings)
        let manager = AudioDeviceManager(settings: settings, displayManager: displays)
        return (manager, settings)
    }

    private func makeDevice(uid: String = "usb-dac", canSetVolume: Bool = false) -> AudioDeviceModel {
        AudioDeviceModel(
            info: .init(
                id: 42,
                uid: uid,
                name: "測試裝置",
                transportType: kAudioDeviceTransportTypeUSB,
                canSetVolume: canSetVolume,
                hasMute: false,
                volume: 0.5,
                muted: false,
                canSetBalance: false,
                balance: 0
            ),
            isDefault: true
        )
    }

    @Test("排除／取消排除寫進設定，並以 UID 為鍵")
    func toggleRoundTrips() {
        let (manager, settings) = makeManager()
        let device = makeDevice()
        #expect(!manager.isExcluded(device))

        manager.setExcluded(true, for: device)
        #expect(manager.isExcluded(device))
        #expect(settings.excludedDevices == ["usb-dac"])

        manager.setExcluded(false, for: device)
        #expect(!manager.isExcluded(device))
        #expect(settings.excludedDevices.isEmpty)
    }

    @Test("排除清單跨重啟保留（同一份 UserDefaults 重建 SettingsStore）")
    func persistsAcrossRestart() {
        let suite = "device-exclusion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        let displays = DisplayManager(settings: settings)
        let manager = AudioDeviceManager(settings: settings, displayManager: displays)
        manager.setExcluded(true, for: makeDevice())

        let second = SettingsStore(defaults: defaults)
        #expect(second.excludedDevices == ["usb-dac"])
    }

    @Test("排除是最強的否決：三個誠實說明都先講排除")
    func exclusionOutranksOtherReasons() {
        let (manager, settings) = makeManager()
        let device = makeDevice()
        // 讓三條路各自「本來就會有話說」：開了軟體音量、設了平衡、開了 EQ
        settings.softwareVolumeDevices = [device.uid]
        settings.deviceBalance[device.uid] = 0.5
        var eq = EQSettings()
        eq.isEnabled = true
        settings.deviceEQ[device.uid] = eq

        manager.setExcluded(true, for: device)
        #expect(manager.softwareVolumeUnavailableReason(device) == AudioDeviceManager.excludedReason)
        #expect(manager.balanceUnavailableReason(for: device) == AudioDeviceManager.excludedReason)
        #expect(manager.eqUnavailableReason(for: device) == AudioDeviceManager.excludedReason)
    }

    @Test("取消排除後設定原樣恢復——排除期間什麼都沒被刪掉")
    func settingsSurviveExclusion() {
        let (manager, settings) = makeManager()
        let device = makeDevice()
        settings.softwareVolumeDevices = [device.uid]
        settings.deviceBalance[device.uid] = -0.4
        var eq = EQSettings()
        eq.isEnabled = true
        settings.deviceEQ[device.uid] = eq

        manager.setExcluded(true, for: device)
        manager.setExcluded(false, for: device)

        #expect(settings.softwareVolumeDevices == [device.uid])
        #expect(settings.deviceBalance[device.uid] == -0.4)
        #expect(settings.deviceEQ[device.uid]?.isEnabled == true)
        // 排除解除 → 理由回到「本來的」那些，不再是排除
        #expect(manager.eqUnavailableReason(for: device) != AudioDeviceManager.excludedReason)
    }

    @Test("排除與隱藏是兩回事：排除的裝置照常顯示")
    func exclusionIsNotHiding() {
        let (manager, _) = makeManager()
        let device = makeDevice()
        manager.setExcluded(true, for: device)
        #expect(!manager.isHidden(device))
    }
}
