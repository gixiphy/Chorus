import Testing
@testable import ChorusCore

@Suite("TapHealthMonitor")
struct TapHealthTests {
    private func window(callbacks: Int = 93, nonZero: Int = 0, audible: Bool) -> TapHealthMonitor.Window {
        .init(callbacks: callbacks, nonZeroCallbacks: nonZero, anySourceAudible: audible)
    }

    @Test("看到非零樣本即判 healthy 並 latch")
    func healthyLatches() {
        var monitor = TapHealthMonitor()
        #expect(monitor.record(window(nonZero: 3, audible: true)) == .healthy)
        // latch：之後就算收到可疑窗也不改判（TCC 中途撤銷需重啟 App）
        for _ in 0..<5 {
            #expect(monitor.record(window(audible: true)) == .healthy)
        }
    }

    @Test("連續兩個「發聲卻全零」的窗 → permissionDenied")
    func deniedAfterConsecutiveAudibleZeroWindows() {
        var monitor = TapHealthMonitor()
        #expect(monitor.record(window(audible: true)) == .undetermined)
        #expect(monitor.record(window(audible: true)) == .permissionDenied)
    }

    @Test("沒發聲的全零窗是正常的——不算證據，也不清除既有嫌疑")
    func silentSourceIsNotEvidence() {
        var monitor = TapHealthMonitor()
        // 大量安靜窗永遠不會誤判
        for _ in 0..<10 {
            #expect(monitor.record(window(audible: false)) == .undetermined)
        }
        // 嫌疑跨安靜窗累積：發聲零窗 → 安靜窗 → 發聲零窗 = 兩次嫌疑
        #expect(monitor.record(window(audible: true)) == .undetermined)
        #expect(monitor.record(window(audible: false)) == .undetermined)
        #expect(monitor.record(window(audible: true)) == .permissionDenied)
    }

    @Test("引擎沒跑（callbacks=0）不算證據")
    func idleEngineIsNotEvidence() {
        var monitor = TapHealthMonitor()
        for _ in 0..<10 {
            #expect(monitor.record(window(callbacks: 0, audible: true)) == .undetermined)
        }
    }

    @Test("denied 也是 latch；reset 後重新累積")
    func deniedLatchesUntilReset() {
        var monitor = TapHealthMonitor()
        _ = monitor.record(window(audible: true))
        _ = monitor.record(window(audible: true))
        #expect(monitor.verdict == .permissionDenied)
        // latch：即使突然收到非零（不可能的順序）也不翻案
        #expect(monitor.record(window(nonZero: 5, audible: true)) == .permissionDenied)
        monitor.reset()
        #expect(monitor.verdict == .undetermined)
        #expect(monitor.record(window(nonZero: 1, audible: true)) == .healthy)
    }
}
