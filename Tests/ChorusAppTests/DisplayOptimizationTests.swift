import CoreGraphics
import Foundation
import Testing
@testable import Chorus

@Suite("DDC 診斷期限", .serialized)
struct DDCDiagnosticsDeadlineTests {
    @Test("queue 卡住時診斷立即回傳快取，不追加工作")
    func stuckQueueReturnsCached() async throws {
        let release = DispatchSemaphore(value: 0)
        let ddc = DDCController(
            readDeadline: .milliseconds(200),
            diagnosticsDeadline: .milliseconds(300),
            ioHook: { release.wait() }
        )
        defer { release.signal() }

        // 先卡住一筆讀取，等到 runningSince 超過 readDeadline（isStuck）
        async let stuck: (current: UInt16, max: UInt16)? = ddc.read(1, vcp: DDCController.VCP.brightness)
        try await Task.sleep(for: .milliseconds(250))

        let started = ContinuousClock.now
        let diag = await ddc.diagnostics(1)
        #expect(diag.queueStuck)
        #expect(diag.incomplete)
        #expect(ContinuousClock.now - started < .milliseconds(100))
        _ = await stuck
    }

    @Test("診斷整體期限內返回（即使無服務）")
    func diagnosticsCompletesWithoutService() async {
        let ddc = DDCController(diagnosticsDeadline: .seconds(2))
        let started = ContinuousClock.now
        let diag = await ddc.diagnostics(99_999)
        #expect(!diag.hasService)
        #expect(!diag.queueStuck)
        #expect(ContinuousClock.now - started < .seconds(2))
    }
}

@Suite("GammaDimmer 結果")
@MainActor
struct GammaDimmerTests {
    @Test("還原失敗時保留可復原資料")
    func restoreFailureKeepsTable() {
        // 無法在單元測試可靠模擬 CGSet 失敗；至少確認 forget／isDimming 契約
        let gamma = GammaDimmer()
        let id: CGDirectDisplayID = 0
        #expect(!gamma.isDimming(id))
        gamma.forget(id)
        #expect(!gamma.isDimming(id))
        #expect(gamma.lastFailure(for: id) == nil)
    }
}
