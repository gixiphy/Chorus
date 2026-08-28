import Testing
@testable import ChorusCore

@Suite("Output priority")
struct OutputPriorityTests {
    @Test("沒設順位＝功能關閉，絕不插手")
    func emptyOrderNeverSwitches() {
        #expect(OutputPriority.preferred(order: [], present: ["a", "b"], current: "b") == nil)
    }

    @Test("順位最前、而且在線的那個")
    func picksTheHighestPresent() {
        #expect(OutputPriority.preferred(
            order: ["airpods", "speakers"], present: ["airpods", "speakers"], current: "speakers"
        ) == "airpods")
    }

    @Test("最高順位不在線就退到下一個")
    func fallsBackWhenTopIsAbsent() {
        #expect(OutputPriority.preferred(
            order: ["airpods", "speakers"], present: ["speakers", "hdmi"], current: "hdmi"
        ) == "speakers")
    }

    @Test("已經是預設就不動——重設一次會讓正在播的音訊斷一下")
    func doesNotReassertTheCurrentDefault() {
        #expect(OutputPriority.preferred(
            order: ["airpods", "speakers"], present: ["airpods", "speakers"], current: "airpods"
        ) == nil)
    }

    @Test("順位裡一個都不在線 → 使用者現在用什麼就是什麼")
    func leavesUnlistedDevicesAlone() {
        #expect(OutputPriority.preferred(
            order: ["airpods"], present: ["hdmi", "speakers"], current: "hdmi"
        ) == nil)
    }

    @Test("還原音量只認順位裡的裝置，且依順位排序")
    func restoresOnlyListedDevices() {
        #expect(OutputPriority.devicesToRestore(
            order: ["airpods", "speakers"], arrived: ["speakers", "airpods", "unknown"]
        ) == ["airpods", "speakers"])
        #expect(OutputPriority.devicesToRestore(order: [], arrived: ["airpods"]).isEmpty)
        #expect(OutputPriority.devicesToRestore(order: ["airpods"], arrived: ["hdmi"]).isEmpty)
    }
}
