import Foundation
import Testing
@testable import Chorus

/// B6-7：提示音音量。
///
/// 注入 fake 的讀寫通道——單元測試不動使用者機器上真正的提示音量。
/// 真實通道是 AppleScript 的 `set volume alert volume`（見 controller
/// 的說明；defaults 鍵在 macOS 26 上已不驅動即時值，D22 實測改判）。
@MainActor
@Suite("Alert volume")
struct AlertVolumeTests {
    @MainActor
    private final class Spy {
        var applied: [Int] = []
        var liveValue: Int? = 85
    }

    private func makeController() -> (AlertVolumeController, Spy) {
        let spy = Spy()
        let controller = AlertVolumeController(
            applyLive: { spy.applied.append($0) },
            readLive: { spy.liveValue }
        )
        return (controller, spy)
    }

    @Test("起始值讀自系統現值，不是憑空給一個")
    func readsTheSystemValue() {
        let (controller, _) = makeController()
        #expect(controller.volume == 0.85)
    }

    @Test("寫入走即時通道（0–100 整數）")
    func writesThroughTheLiveChannel() {
        let (controller, spy) = makeController()
        controller.setVolume(0.25)
        #expect(spy.applied == [25])
        #expect(controller.volume == 0.25)
    }

    @Test("夾在 0–1")
    func clampsToUnitRange() {
        let (controller, spy) = makeController()
        controller.setVolume(3)
        #expect(controller.volume == 1)
        controller.setVolume(-1)
        #expect(controller.volume == 0)
        #expect(spy.applied == [100, 0])
    }

    @Test("refresh 讀回外部改動——系統設定可能剛被別人改過")
    func refreshPicksUpExternalChanges() {
        let (controller, spy) = makeController()
        spy.liveValue = 50
        controller.refresh()
        #expect(controller.volume == 0.5)
    }

    @Test("讀不到現值時退回 1（提示音預設就是全音量），不是 0 或垃圾值")
    func fallsBackToFullVolumeWhenUnreadable() {
        let (controller, spy) = makeController()
        spy.liveValue = nil
        controller.refresh()
        #expect(controller.volume == 1)
    }
}
