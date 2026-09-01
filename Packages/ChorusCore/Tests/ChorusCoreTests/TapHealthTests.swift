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

    // MARK: - 裝置變動的 hold（藍牙重協商不該被當成權限被拒）

    @Test("裝置變動清掉既有嫌疑，之後數個窗不算證據")
    func deviceChangeClearsSuspicionAndHolds() {
        var monitor = TapHealthMonitor()
        // 事件抵達前已經記了一次嫌疑（全零往往比通知早開始）
        #expect(monitor.record(window(audible: true)) == .undetermined)
        monitor.noteDeviceChanged()
        // hold 期間：重協商的空隙長得跟權限被拒一模一樣，全部不算
        for _ in 0..<3 {
            #expect(monitor.record(window(audible: true)) == .undetermined)
        }
        // hold 過期 → 回到原判準，從零重新累積
        #expect(monitor.record(window(audible: true)) == .undetermined)
        #expect(monitor.record(window(audible: true)) == .permissionDenied)
    }

    @Test("hold 期間看到非零樣本仍然 latch healthy")
    func holdStillAllowsHealthy() {
        var monitor = TapHealthMonitor()
        monitor.noteDeviceChanged()
        // 正面證據在任何情況下都成立——權限有就是有
        #expect(monitor.record(window(nonZero: 7, audible: true)) == .healthy)
    }

    @Test("已 latch 時 noteDeviceChanged 是 no-op")
    func deviceChangeDoesNotUnlatch() {
        var monitor = TapHealthMonitor()
        _ = monitor.record(window(nonZero: 3, audible: true))
        #expect(monitor.verdict == .healthy)
        monitor.noteDeviceChanged()
        #expect(monitor.verdict == .healthy)

        var denied = TapHealthMonitor()
        _ = denied.record(window(audible: true))
        _ = denied.record(window(audible: true))
        #expect(denied.verdict == .permissionDenied)
        denied.noteDeviceChanged()
        #expect(denied.verdict == .permissionDenied)
    }

    @Test("hold 被任何窗消耗，包含沒發聲的窗")
    func holdIsConsumedByAnyWindow() {
        var monitor = TapHealthMonitor()
        monitor.noteDeviceChanged()
        for _ in 0..<3 {
            #expect(monitor.record(window(audible: false)) == .undetermined)
        }
        // 三個無聲窗把 hold 用完 → 接著兩個可疑窗就該判定
        #expect(monitor.record(window(audible: true)) == .undetermined)
        #expect(monitor.record(window(audible: true)) == .permissionDenied)
    }

    @Test("重複的裝置變動是重置 hold，不是累加")
    func repeatedDeviceChangeResetsHold() {
        var monitor = TapHealthMonitor()
        monitor.noteDeviceChanged()
        _ = monitor.record(window(audible: true))   // 剩 2
        monitor.noteDeviceChanged()                 // 回到 3，不是 5
        for _ in 0..<3 {
            #expect(monitor.record(window(audible: true)) == .undetermined)
        }
        #expect(monitor.record(window(audible: true)) == .undetermined)
        #expect(monitor.record(window(audible: true)) == .permissionDenied)
    }

    @Test("引擎沒跑的窗不消耗 hold（callbacks=0 連判準都到不了）")
    func idleWindowsDoNotConsumeHold() {
        var monitor = TapHealthMonitor(holdWindowsAfterDeviceChange: 1)
        monitor.noteDeviceChanged()
        for _ in 0..<5 {
            #expect(monitor.record(window(callbacks: 0, audible: true)) == .undetermined)
        }
        // hold 還在（沒被空轉的窗吃掉）
        #expect(monitor.record(window(audible: true)) == .undetermined)
        #expect(monitor.record(window(audible: true)) == .undetermined)
        #expect(monitor.record(window(audible: true)) == .permissionDenied)
    }
}
