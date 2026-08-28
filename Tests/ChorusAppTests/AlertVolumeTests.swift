import Foundation
import Testing
@testable import Chorus

/// B6-7：提示音音量。
///
/// 用自己的 suite **寫**，不碰使用者機器上真正的提示音音量。
/// 注意**讀**仍會穿透到 NSGlobalDomain（UserDefaults 的搜尋清單一定
/// 包含全域網域）——所以測試一律先寫再讀，不假設起始值。
/// 這個穿透在正式路徑上正是我們要的：沒寫過就讀系統現值。
@MainActor
@Suite("Alert volume")
struct AlertVolumeTests {
    private func makeController() -> (AlertVolumeController, UserDefaults) {
        let defaults = UserDefaults(suiteName: "alert-\(UUID().uuidString)")!
        return (AlertVolumeController(defaults: defaults), defaults)
    }

    @Test("起始值讀自系統設定，不是憑空給一個")
    func readsTheSystemValue() {
        let (controller, defaults) = makeController()
        let system = defaults.object(forKey: "com.apple.sound.beep.volume") as? Double
        #expect(controller.volume == (system ?? 1))
        #expect((0...1).contains(controller.volume))
    }

    @Test("寫進系統設定用的那個鍵")
    func writesTheSystemKey() {
        let (controller, defaults) = makeController()
        controller.setVolume(0.25)
        #expect(defaults.object(forKey: "com.apple.sound.beep.volume") as? Double == 0.25)
        #expect(controller.volume == 0.25)
    }

    @Test("夾在 0–1")
    func clampsToUnitRange() {
        let (controller, _) = makeController()
        controller.setVolume(3)
        #expect(controller.volume == 1)
        controller.setVolume(-1)
        #expect(controller.volume == 0)
    }

    @Test("refresh 讀回外部改動——系統設定可能剛被別人改過")
    func refreshPicksUpExternalChanges() {
        let (controller, defaults) = makeController()
        defaults.set(0.5, forKey: "com.apple.sound.beep.volume")
        controller.refresh()
        #expect(controller.volume == 0.5)
    }
}
