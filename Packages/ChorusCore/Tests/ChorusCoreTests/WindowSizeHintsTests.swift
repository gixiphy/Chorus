import Testing
@testable import ChorusCore

@Suite("WindowSizeHints")
struct WindowSizeHintsTests {
    @Test("要求 400 讀回 520 → 只記寬度下限")
    func widthOnlyLowerBound() {
        var hints = WindowSizeHints()
        hints.recordReadBack(
            token: "w1",
            requested: LayoutRect(x: 0, y: 0, width: 400, height: 300),
            actual: LayoutRect(x: 0, y: 0, width: 520, height: 300)
        )
        #expect(hints.minimumSize(for: "w1") == LayoutSize(width: 520, height: 0))
    }

    @Test("下限只升不降")
    func monotonic() {
        var hints = WindowSizeHints()
        hints.recordReadBack(
            token: "w1",
            requested: LayoutRect(x: 0, y: 0, width: 400, height: 300),
            actual: LayoutRect(x: 0, y: 0, width: 520, height: 300)
        )
        hints.recordReadBack(
            token: "w1",
            requested: LayoutRect(x: 0, y: 0, width: 400, height: 300),
            actual: LayoutRect(x: 0, y: 0, width: 480, height: 300)
        )
        #expect(hints.minimumSize(for: "w1")?.width == 520)
    }

    @Test("容差內差異忽略")
    func withinToleranceIgnored() {
        var hints = WindowSizeHints()
        hints.recordReadBack(
            token: "w1",
            requested: LayoutRect(x: 0, y: 0, width: 400, height: 300),
            actual: LayoutRect(x: 0, y: 0, width: 402, height: 301)
        )
        #expect(hints.minimumSize(for: "w1") == nil)
    }

    @Test("回報最小尺寸與既有下限取 max")
    func reportedMerges() {
        var hints = WindowSizeHints()
        hints.recordReadBack(
            token: "w1",
            requested: LayoutRect(x: 0, y: 0, width: 400, height: 200),
            actual: LayoutRect(x: 0, y: 0, width: 500, height: 200)
        )
        hints.recordReported(token: "w1", minimum: LayoutSize(width: 450, height: 360))
        #expect(hints.minimumSize(for: "w1") == LayoutSize(width: 500, height: 360))
    }

    @Test("forget 清除提示")
    func forget() {
        var hints = WindowSizeHints()
        hints.recordReported(token: "w1", minimum: LayoutSize(width: 100, height: 100))
        hints.forget(token: "w1")
        #expect(hints.minimumSize(for: "w1") == nil)
    }
}
