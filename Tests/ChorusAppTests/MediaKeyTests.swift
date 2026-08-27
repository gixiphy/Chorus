import Testing
@testable import Chorus

/// MediaKeyInterceptor 的純邏輯：NX_SYSDEFINED data1 解析、接管條件、步進夾值。
@Suite("Media key interception")
struct MediaKeyTests {
    /// data1 佈局：bits16–31 keyCode、bits8–15 0x0A(down)/0x0B(up)、bit0 repeat。
    private func data1(keyCode: Int32, down: Bool, repeated: Bool = false) -> Int {
        (Int(keyCode) << 16) | ((down ? 0x0A : 0x0B) << 8) | (repeated ? 1 : 0)
    }

    @Test("data1 解析：keyDown / keyUp / repeat")
    func parseData1() {
        let down = MediaKeyInterceptor.parse(data1: data1(keyCode: 0, down: true))
        #expect(down == .init(keyCode: 0, isDown: true, isRepeat: false))

        let up = MediaKeyInterceptor.parse(data1: data1(keyCode: 7, down: false))
        #expect(up == .init(keyCode: 7, isDown: false, isRepeat: false))

        let repeated = MediaKeyInterceptor.parse(data1: data1(keyCode: 2, down: true, repeated: true))
        #expect(repeated == .init(keyCode: 2, isDown: true, isRepeat: true))
    }

    @Test("data1 解析：非按鍵狀態值拒收")
    func parseRejectsNonKeyStates() {
        // caps lock 燈等其他 subtype-8 事件的 state 欄位不是 0x0A/0x0B
        #expect(MediaKeyInterceptor.parse(data1: (5 << 16) | (0x00 << 8)) == nil)
        #expect(MediaKeyInterceptor.parse(data1: 0) == nil)
    }

    @Test("音量接管條件：只在無 CoreAudio 音量且已橋接時")
    func volumeInterceptCondition() {
        #expect(MediaKeyInterceptor.shouldInterceptVolume(canSetVolume: false, bridged: true))
        #expect(!MediaKeyInterceptor.shouldInterceptVolume(canSetVolume: true, bridged: false))
        #expect(!MediaKeyInterceptor.shouldInterceptVolume(canSetVolume: true, bridged: true))
        #expect(!MediaKeyInterceptor.shouldInterceptVolume(canSetVolume: false, bridged: false))
    }

    @Test("亮度接管條件：只在沒有任何 DisplayServices 顯示器時")
    func brightnessInterceptCondition() {
        #expect(MediaKeyInterceptor.shouldInterceptBrightness(backends: [.ddc]))
        #expect(MediaKeyInterceptor.shouldInterceptBrightness(backends: [.ddc, .gammaOnly]))
        #expect(!MediaKeyInterceptor.shouldInterceptBrightness(backends: [.displayServices]))
        #expect(!MediaKeyInterceptor.shouldInterceptBrightness(backends: [.ddc, .displayServices]))
        #expect(!MediaKeyInterceptor.shouldInterceptBrightness(backends: []))
    }

    @Test("步進：1/16 刻度、0–1 夾值")
    func stepping() {
        #expect(abs(MediaKeyInterceptor.stepped(0.5, up: true) - (0.5 + 1.0 / 16)) < 1e-9)
        #expect(abs(MediaKeyInterceptor.stepped(0.5, up: false) - (0.5 - 1.0 / 16)) < 1e-9)
        #expect(MediaKeyInterceptor.stepped(0.99, up: true) == 1.0)
        #expect(MediaKeyInterceptor.stepped(0.01, up: false) == 0.0)
    }
}
