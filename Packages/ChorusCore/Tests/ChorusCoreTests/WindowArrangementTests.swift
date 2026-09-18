import Testing
@testable import ChorusCore

@Suite("WindowArrangement")
struct WindowArrangementTests {
    private let visible = LayoutRect(x: 0, y: 0, width: 1600, height: 900)

    @Test("格數：左右 2、1 大 2 小 3、三欄 3、四分 4")
    func slotCounts() {
        #expect(WindowArrangement.leftRight.slotCount == 2)
        #expect(WindowArrangement.mainLeft.slotCount == 3)
        #expect(WindowArrangement.mainRight.slotCount == 3)
        #expect(WindowArrangement.threeColumns.slotCount == 3)
        #expect(WindowArrangement.quarters.slotCount == 4)
    }

    @Test("1 大 2 小（左大）：第一格是左半全高，其餘是右上、右下")
    func mainLeft() {
        let frames = WindowArrangement.mainLeft.frames(visible: visible, gap: 8)
        #expect(frames.count == 3)
        // 內矩形 8…1592 × 8…892；中線 800、792/2 → 450
        #expect(frames[0] == LayoutRect(x: 8, y: 8, width: 788, height: 884))
        #expect(frames[1] == LayoutRect(x: 804, y: 454, width: 788, height: 438))
        #expect(frames[2] == LayoutRect(x: 804, y: 8, width: 788, height: 438))
    }

    @Test("1 大 2 小（右大）是左大的鏡像，主要視窗仍排第一")
    func mainRightMirrors() {
        let frames = WindowArrangement.mainRight.frames(visible: visible, gap: 8)
        #expect(frames[0] == LayoutRect(x: 804, y: 8, width: 788, height: 884))
        #expect(frames[1].x == 8)
        #expect(frames[1].y > frames[2].y)
    }

    @Test("各格互不重疊、間距一致，且與單視窗動作的幾何相同")
    func consistentWithSingleActions() {
        let engine = LayoutEngine()
        let lr = WindowArrangement.leftRight.frames(visible: visible, gap: 8)
        #expect(lr[0] == engine.frame(for: .leftHalf, visible: visible, gap: 8))
        #expect(lr[1] == engine.frame(for: .rightHalf, visible: visible, gap: 8))

        let q = WindowArrangement.quarters.frames(visible: visible, gap: 8)
        #expect(q[0] == engine.frame(for: .topLeft, visible: visible, gap: 8))
        #expect(q[1] == engine.frame(for: .topRight, visible: visible, gap: 8))
        #expect(q[2] == engine.frame(for: .bottomLeft, visible: visible, gap: 8))
        #expect(q[3] == engine.frame(for: .bottomRight, visible: visible, gap: 8))

        let c = WindowArrangement.threeColumns.frames(visible: visible, gap: 8)
        #expect(c[1] == engine.frame(for: .centerThird, visible: visible, gap: 8))

        for arrangement in WindowArrangement.allCases {
            let frames = arrangement.frames(visible: visible, gap: 8)
            for (i, a) in frames.enumerated() {
                for b in frames[(i + 1)...] {
                    #expect(a.intersection(b) == nil)
                }
            }
        }
    }

    @Test("視窗不夠時只用前幾格；主要視窗永遠拿第一格")
    func assignment() {
        let frames = WindowArrangement.quarters.frames(visible: visible, gap: 0)
        let plan = WindowArrangement.quarters.plan(windows: ["a", "b"], visible: visible, gap: 0)
        #expect(plan.map(\.window) == ["a", "b"])
        #expect(plan.map(\.frame) == Array(frames.prefix(2)))
        let many = WindowArrangement.leftRight.plan(windows: ["a", "b", "c"], visible: visible, gap: 0)
        #expect(many.map(\.window) == ["a", "b"])
    }

    @Test("排列指令對應到佈局，且不算在截圖的 19 個單視窗動作裡")
    func commands() {
        #expect(WindowCommand.arrangeMainLeft.arrangement == .mainLeft)
        #expect(WindowCommand.arrangeMainLeft.rawValue == "arrange-main-left")
        #expect(WindowCommand.arrangeMainLeft.layoutAction == nil)
        #expect(WindowCommand.leftHalf.arrangement == nil)
        #expect(WindowCommand.commands(in: .arrange).count == WindowArrangement.allCases.count)
        #expect(ShortcutBindings()[.arrangeMainLeft] == nil)
    }
}
