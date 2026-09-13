import CoreGraphics
import Foundation
import Testing
@testable import Chorus

/// Batch E：DDC queue 卡住（I2C 呼叫不回來）時，讀取有期限、卡住後不再排隊。
/// 用 `ioHook` 模擬卡住，不碰真的 I2C。
@Suite("DDC 讀取期限", .serialized)
struct DDCDeadlineTests {
    @Test("I2C 卡住：讀取在期限內回 nil；卡住期間的新讀取立刻回 nil")
    func stuckReadIsBounded() async throws {
        let release = DispatchSemaphore(value: 0)
        let ddc = DDCController(readDeadline: .milliseconds(200), ioHook: { release.wait() })
        defer { release.signal() }

        let started = ContinuousClock.now
        let first = await ddc.read(1, vcp: DDCController.VCP.brightness)
        #expect(first == nil)
        #expect(ContinuousClock.now - started < .seconds(2))

        try await Task.sleep(for: .milliseconds(100))
        let immediate = ContinuousClock.now
        let second = await ddc.read(1, vcp: DDCController.VCP.brightness)
        #expect(second == nil)
        #expect(ContinuousClock.now - immediate < .milliseconds(100))
    }

    @Test("掃描卡住：期限到回空集合（顯示器降級，不是整個列舉卡住）")
    func stuckRefreshIsBounded() async {
        let release = DispatchSemaphore(value: 0)
        let ddc = DDCController(refreshDeadline: .milliseconds(200), ioHook: { release.wait() })
        defer { release.signal() }

        let started = ContinuousClock.now
        let capable = await ddc.refresh(displayIDs: [1, 2])
        #expect(capable.isEmpty)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("沒卡住時讀取照常完成（沒有服務的顯示器回 nil，不等期限）")
    func normalReadIsNotDelayed() async {
        let ddc = DDCController(readDeadline: .seconds(5))
        let started = ContinuousClock.now
        let value = await ddc.read(12_345, vcp: DDCController.VCP.brightness)
        #expect(value == nil)
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
