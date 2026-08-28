import Testing
@testable import ChorusCore

@Suite("EmergencyGestureDetector")
struct EmergencyGestureTests {
    @Test("Eight presses inside the window fire the gesture")
    func fires() {
        var detector = EmergencyGestureDetector(requiredCount: 8, window: 3)
        var fired = false
        for i in 0..<8 {
            fired = detector.record(at: Double(i) * 0.2)
        }
        #expect(fired)
    }

    @Test("Seven presses are not enough")
    func notEnough() {
        var detector = EmergencyGestureDetector(requiredCount: 8, window: 3)
        for i in 0..<7 {
            let fired = detector.record(at: Double(i) * 0.2)
            #expect(!fired)
        }
        #expect(detector.pendingCount == 7)
    }

    @Test("Presses spread beyond the window never accumulate")
    func tooSlow() {
        var detector = EmergencyGestureDetector(requiredCount: 8, window: 3)
        for i in 0..<20 {
            // 每次間隔 4 秒 > 3 秒時間窗：永遠只剩最新一次
            let fired = detector.record(at: Double(i) * 4)
            #expect(!fired)
        }
        #expect(detector.pendingCount == 1)
    }

    @Test("Firing resets, so holding the key down does not retrigger every press")
    func resetsAfterFiring() {
        var detector = EmergencyGestureDetector(requiredCount: 8, window: 3)
        for i in 0..<8 { _ = detector.record(at: Double(i) * 0.1) }
        #expect(detector.pendingCount == 0)
        let refired = detector.record(at: 0.9)
        #expect(!refired)
    }

    @Test("Stale presses are dropped as the window slides")
    func slidingWindow() {
        var detector = EmergencyGestureDetector(requiredCount: 8, window: 3)
        // 4 次很早、4 次很晚：加起來 8 次但跨不進同一個時間窗
        for i in 0..<4 { _ = detector.record(at: Double(i) * 0.1) }
        for i in 0..<3 {
            let fired = detector.record(at: 10 + Double(i) * 0.1)
            #expect(!fired)
        }
        #expect(detector.pendingCount == 3)
    }
}
