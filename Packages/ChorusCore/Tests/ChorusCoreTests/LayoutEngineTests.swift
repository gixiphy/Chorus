import Testing
@testable import ChorusCore

@Suite("LayoutEngine")
struct LayoutEngineTests {
    private let engine = LayoutEngine()
    private let screen = LayoutRect(x: 100, y: 50, width: 1600, height: 900)

    @Test("左半屏：外間距後對半，共用邊再退 gap/2")
    func leftHalf() {
        let result = engine.frame(for: .leftHalf, visible: screen, gap: 8)
        // 內矩形：x=108, y=58, w=1584, h=884；中線 900；右側退 4 → 寬 788
        #expect(result == LayoutRect(x: 108, y: 58, width: 788, height: 884))
    }

    @Test("右半屏與左半屏共用邊界並各退 gap/2")
    func rightHalfSharesBoundary() {
        let left = engine.frame(for: .leftHalf, visible: screen, gap: 8)
        let right = engine.frame(for: .rightHalf, visible: screen, gap: 8)
        #expect(left.maxX + 8 == right.x)
        #expect(right.maxX == screen.maxX - 8)
        #expect(left.width + right.width + 8 == 1584)
    }

    @Test("三分之一：三區等分後餘數進最後一區，相鄰各退 gap/2")
    func thirds() {
        let left = engine.frame(for: .leftThird, visible: screen, gap: 8)
        let center = engine.frame(for: .centerThird, visible: screen, gap: 8)
        let right = engine.frame(for: .rightThird, visible: screen, gap: 8)
        #expect(left.x == 108)
        #expect(left.maxX + 8 == center.x)
        #expect(center.maxX + 8 == right.x)
        #expect(right.maxX == screen.maxX - 8)
        #expect(left.width + center.width + right.width + 16 == 1584)
    }

    @Test("左三分之二與右三分之一對齊")
    func leftTwoThirds() {
        let wide = engine.frame(for: .leftTwoThirds, visible: screen, gap: 8)
        let thin = engine.frame(for: .rightThird, visible: screen, gap: 8)
        #expect(wide.maxX + 8 == thin.x)
        #expect(wide.maxX == thin.x - 8)
    }

    @Test("四分之一四欄相接；左／右四分之三與另一側的四分之一對齊")
    func fourths() {
        let actions: [LayoutAction] = [.firstFourth, .secondFourth, .thirdFourth, .lastFourth]
        let columns = actions.map { engine.frame(for: $0, visible: screen, gap: 8) }
        #expect(columns[0].x == 108)
        for (a, b) in zip(columns, columns.dropFirst()) {
            #expect(a.maxX + 8 == b.x)
        }
        #expect(columns[3].maxX == screen.maxX - 8)
        #expect(columns.map(\.width).reduce(0, +) + 24 == 1584)

        let leftWide = engine.frame(for: .leftThreeFourths, visible: screen, gap: 8)
        let rightWide = engine.frame(for: .rightThreeFourths, visible: screen, gap: 8)
        #expect(leftWide.x == columns[0].x)
        #expect(leftWide.maxX + 8 == columns[3].x)
        #expect(columns[0].maxX + 8 == rightWide.x)
        #expect(rightWide.maxX == columns[3].maxX)
    }

    @Test("中央三分之二：全高、左右各留 1/6，不再扣內間距")
    func centerTwoThirds() {
        let result = engine.frame(for: .centerTwoThirds, visible: screen, gap: 8)
        // 內矩形 w=1584 → 左右各留 264，寬 1056
        #expect(result == LayoutRect(x: 372, y: 58, width: 1056, height: 884))
    }

    @Test("中央三分之二：非整除寬度仍左右對稱")
    func centerTwoThirdsSymmetric() {
        let odd = LayoutRect(x: 0, y: 0, width: 1001, height: 600)
        let result = engine.frame(for: .centerTwoThirds, visible: odd, gap: 0)
        #expect(result.x - odd.x == odd.maxX - result.maxX)
        #expect(result.height == 600)
    }

    @Test("填滿＝可見範圍內縮 gap")
    func maximize() {
        let result = engine.frame(for: .maximize, visible: screen, gap: 8)
        #expect(result == LayoutRect(x: 108, y: 58, width: 1584, height: 884))
    }

    @Test("置中維持尺寸：把 current 放到內矩形中央")
    func centerPreserveSize() {
        let current = LayoutRect(x: 0, y: 0, width: 400, height: 300)
        let result = engine.frame(
            for: .centerPreserveSize,
            visible: screen,
            gap: 8,
            current: current
        )
        #expect(result.width == 400)
        #expect(result.height == 300)
        #expect(result.x == 108 + (1584 - 400) / 2)
        #expect(result.y == 58 + (884 - 300) / 2)
    }

    @Test("gap 為 0 時半屏無縫相接")
    func zeroGap() {
        let left = engine.frame(for: .leftHalf, visible: screen, gap: 0)
        let right = engine.frame(for: .rightHalf, visible: screen, gap: 0)
        #expect(left.maxX == right.x)
        #expect(left.width + right.width == 1600)
    }

    @Test("ultrawideZone 直接使用傳入 zone（已含間距）")
    func ultrawideZonePassthrough() {
        let zone = LayoutRect(x: 200, y: 60, width: 800, height: 800)
        let result = engine.frame(for: .ultrawideZone, visible: screen, gap: 8, zone: zone)
        #expect(result == zone)
    }
}
