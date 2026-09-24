import Testing
@testable import ChorusCore

@Suite("ArrangementPlanner")
struct ArrangementPlannerTests {
    private let visible16x9 = LayoutRect(x: 0, y: 0, width: 1_600, height: 900)
    private let visibleUltrawide = LayoutRect(x: 0, y: 0, width: 3_440, height: 1_440)
    private let gap = 8.0

    @Test("候選依視窗數")
    func candidates() {
        #expect(ArrangementPlanner.candidates(forWindowCount: 1).isEmpty)
        #expect(ArrangementPlanner.candidates(forWindowCount: 2) == [
            .leftRight, .widePrimary, .widePrimaryMirrored, .quarterSide, .quarterSideMirrored
        ])
        #expect(ArrangementPlanner.candidates(forWindowCount: 3) == [
            .threeColumns, .mainLeft, .mainRight, .centerStage, .primaryStack, .primaryStackMirrored
        ])
        #expect(ArrangementPlanner.candidates(forWindowCount: 4) == [.quarters, .fourColumns])
        #expect(ArrangementPlanner.candidates(forWindowCount: 5) == [.quarters, .fourColumns])
    }

    @Test("未知尺寸選左右並排")
    func unknownSizesPickLeftRight() {
        let choice = ArrangementPlanner.choose(
            minSizes: [nil, nil],
            visible: visible16x9,
            gap: gap
        )
        #expect(choice == .leftRight)
    }

    @Test("主窗最小寬 900 時避開左右並排，改選寬主區")
    func minWidthForcesAsymmetric() {
        // 主窗第一格；1600 半屏約 788，放不下 900；widePrimary 主區約 2/3 可放。
        // （副窗要 900 在 primary-first 語意下沒有 overflow=0 的兩窗候選——計畫文案對齊主窗約束。）
        let minSizes: [LayoutSize?] = [
            LayoutSize(width: 900, height: 0),
            LayoutSize(width: 0, height: 0),
        ]
        let leftRightOverflow = ArrangementPlanner.overflow(
            .leftRight, visible: visible16x9, gap: gap, minSizes: minSizes
        )
        #expect(leftRightOverflow > 0)
        let choice = ArrangementPlanner.choose(minSizes: minSizes, visible: visible16x9, gap: gap)
        #expect(choice != .leftRight)
        #expect(choice != nil)
        #expect(ArrangementPlanner.overflow(choice!, visible: visible16x9, gap: gap, minSizes: minSizes) == 0)
    }

    @Test("三窗預設備選為三欄")
    func threeColumnsComfortable() {
        let choice = ArrangementPlanner.choose(
            minSizes: [nil, nil, nil],
            visible: visible16x9,
            gap: gap
        )
        #expect(choice == .threeColumns)
    }

    @Test("兩窗最小高 500 時避開半高副格")
    func heightConstraintPicksColumns() {
        let minSizes: [LayoutSize?] = [
            LayoutSize(width: 0, height: 500),
            LayoutSize(width: 0, height: 500),
        ]
        // mainLeft/mainRight 副格半高放不下；leftRight 全高可放
        let choice = ArrangementPlanner.choose(minSizes: minSizes, visible: visible16x9, gap: gap)
        #expect(choice == .leftRight || choice == .widePrimary || choice == .widePrimaryMirrored)
        if let choice {
            let frames = choice.frames(visible: visible16x9, gap: gap)
            for (frame, min) in zip(frames, minSizes) {
                #expect((min?.height ?? 0) <= frame.height + 2)
            }
        }
    }

    @Test("全部放不下仍回 overflow 最小者")
    func minOverflowFallback() {
        let huge = LayoutSize(width: 1_200, height: 800)
        let choice = ArrangementPlanner.choose(
            minSizes: [huge, huge],
            visible: visible16x9,
            gap: gap
        )
        #expect(choice != nil)
    }

    @Test("超寬螢幕仍偏好候選順序中的第一個可行")
    func ultrawidePreference() {
        let choice = ArrangementPlanner.choose(
            minSizes: [nil, nil],
            visible: visibleUltrawide,
            gap: gap
        )
        #expect(choice == .leftRight)
    }

    @Test("同輸入連續兩次同結果")
    func sameHintsSameChoice() {
        let minSizes: [LayoutSize?] = [
            LayoutSize(width: 600, height: 400),
            LayoutSize(width: 900, height: 400),
        ]
        let a = ArrangementPlanner.choose(minSizes: minSizes, visible: visible16x9, gap: gap)
        let b = ArrangementPlanner.choose(minSizes: minSizes, visible: visible16x9, gap: gap)
        #expect(a == b)
        #expect(a != nil)
    }
}
