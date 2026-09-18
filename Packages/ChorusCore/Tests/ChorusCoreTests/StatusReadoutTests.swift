import Testing
@testable import ChorusCore

@Suite("選單列圖示的讀數：只在調整時出現")
struct StatusReadoutTests {
    @Test("讀數是四捨五入的整數百分比")
    func percent() {
        #expect(StatusReadout(kind: .brightness, value: 0.756).percent == 76)
        #expect(StatusReadout(kind: .volume, value: 0.004).percent == 0)
        #expect(StatusReadout(kind: .volume, value: 1.3).percent == 100)
        #expect(StatusReadout(kind: .volume, value: -0.2).percent == 0)
    }

    @Test("讀數變了就是不同 state，圖示會重畫")
    func stateIncludesReadout() {
        let plain = StatusIconState(brightness: 0.5, volume: 0.5, isMuted: false, badge: nil)
        var showing = plain
        showing.readout = StatusReadout(kind: .brightness, value: 0.5)
        #expect(plain != showing)
        #expect(plain.readout == nil)
    }

    @Test("顯示後在停留時間內看得到，到期自動收掉")
    @MainActor
    func expires() async throws {
        let controller = StatusReadoutController(hold: .milliseconds(60))
        controller.show(.brightness, value: 0.42)
        #expect(controller.readout == StatusReadout(kind: .brightness, value: 0.42))
        try await Task.sleep(for: .milliseconds(200))
        #expect(controller.readout == nil)
    }

    @Test("連續調整會延長停留，並以最後一次的值與種類為準")
    @MainActor
    func restartsHold() async throws {
        let controller = StatusReadoutController(hold: .milliseconds(120))
        controller.show(.brightness, value: 0.40)
        try await Task.sleep(for: .milliseconds(80))
        controller.show(.volume, value: 0.55)
        try await Task.sleep(for: .milliseconds(80))
        // 第一次的 120ms 早就過了，但第二次把時鐘重設，所以還在
        #expect(controller.readout == StatusReadout(kind: .volume, value: 0.55))
        try await Task.sleep(for: .milliseconds(150))
        #expect(controller.readout == nil)
    }
}
