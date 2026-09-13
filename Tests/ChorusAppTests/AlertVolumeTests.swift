import Foundation
import Synchronization
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
    /// 讀寫通道在背景 queue 上被呼叫，spy 要能跨執行緒。
    private final class Spy: Sendable {
        private let state = Mutex<(applied: [Int], live: Int?, reads: Int)>(([], 85, 0))

        var applied: [Int] { state.withLock { $0.applied } }
        var reads: Int { state.withLock { $0.reads } }

        func setLive(_ value: Int?) {
            state.withLock { $0.live = value }
        }

        func apply(_ value: Int) {
            state.withLock { $0.applied.append(value) }
        }

        func read() -> Int? {
            state.withLock { state in
                state.reads += 1
                return state.live
            }
        }
    }

    private func makeController(refreshOnInit: Bool = false) -> (AlertVolumeController, Spy) {
        let spy = Spy()
        let controller = AlertVolumeController(
            applyLive: { spy.apply($0) },
            readLive: { spy.read() },
            refreshOnInit: refreshOnInit
        )
        return (controller, spy)
    }

    @Test("起始值讀自系統現值——在背景讀，建立時不同步等 AppleScript")
    func readsTheSystemValueInBackground() async {
        let (controller, _) = makeController(refreshOnInit: true)
        #expect(!controller.isKnown)
        await controller.refreshInBackground().value
        #expect(controller.volume == 0.85)
        #expect(controller.isKnown)
    }

    @Test("寫入走即時通道（0–100 整數），在背景執行")
    func writesThroughTheLiveChannel() async {
        let (controller, spy) = makeController()
        controller.setVolume(0.25)
        #expect(controller.volume == 0.25)
        await controller.waitForPendingWrites()
        #expect(spy.applied == [25])
    }

    @Test("夾在 0–1")
    func clampsToUnitRange() async {
        let (controller, spy) = makeController()
        controller.setVolume(3)
        #expect(controller.volume == 1)
        controller.setVolume(-1)
        #expect(controller.volume == 0)
        await controller.waitForPendingWrites()
        #expect(spy.applied == [100, 0])
    }

    @Test("refresh 讀回外部改動——系統設定可能剛被別人改過")
    func refreshPicksUpExternalChanges() {
        let (controller, spy) = makeController()
        spy.setLive(50)
        controller.refresh()
        #expect(controller.volume == 0.5)
    }

    @Test("讀不到現值時退回 1（提示音預設就是全音量），不是 0 或垃圾值")
    func fallsBackToFullVolumeWhenUnreadable() {
        let (controller, spy) = makeController()
        spy.setLive(nil)
        controller.refresh()
        #expect(controller.volume == 1)
        #expect(!controller.isKnown)
    }

    @Test("背景讀取期間使用者拉了滑桿：舊讀值不蓋掉使用者的值")
    func userWinsOverLateRead() async {
        let (controller, _) = makeController()
        let pending = controller.refreshInBackground()
        controller.setVolume(0.3)
        await pending.value
        #expect(controller.volume == 0.3)
    }

    @Test("背景讀取同時只有一輪")
    func singleFlightRefresh() async {
        let (controller, spy) = makeController()
        let first = controller.refreshInBackground()
        let second = controller.refreshInBackground()
        await first.value
        await second.value
        #expect(spy.reads == 1)
    }

    @Test("拖桿：只套用尾端那一筆")
    func coalescedDragAppliesTail() async throws {
        let (controller, spy) = makeController()
        for value in [0.1, 0.2, 0.3, 0.4] {
            controller.setVolumeCoalesced(value)
        }
        #expect(controller.volume == 0.4)
        try await Task.sleep(for: .milliseconds(250))
        await controller.waitForPendingWrites()
        #expect(spy.applied == [40])
    }
}
