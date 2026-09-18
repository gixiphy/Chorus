import Testing
@testable import ChorusCore

@Suite("LayoutTemplate")
struct LayoutTemplateTests {
    private let visible = LayoutRect(x: 0, y: 0, width: 3440, height: 1440)
    private let gap = 8.0

    @Test("中央主區 1:2:1 三區全高")
    func centerStage() {
        let template = LayoutTemplateCatalog.template(id: .centerStage)
        let zones = template.resolvedZones(visible: visible, gap: gap)
        #expect(zones.count == 3)
        #expect(zones.map(\.0.id) == ["left", "center", "right"])
        let widths = zones.map(\.1.width)
        // 內寬 3424；切點 0/.25/.75/1 → 856 / 1712 / 856，再扣共用邊
        #expect(widths[0] + widths[1] + widths[2] + 16 == 3424)
        #expect(zones[1].1.width > zones[0].1.width)
        #expect(zones.allSatisfy { $0.1.height == 1424 })
    }

    @Test("四欄等分")
    func fourColumns() {
        let zones = LayoutTemplateCatalog.template(id: .fourColumns)
            .resolvedZones(visible: visible, gap: gap)
        #expect(zones.count == 4)
        #expect(zones.map(\.1.width).reduce(0, +) + 24 == 3424)
    }

    @Test("主區＋雙側窗：主區 2/3，側欄上下各半")
    func primaryStack() {
        let zones = LayoutTemplateCatalog.template(id: .primaryStack)
            .resolvedZones(visible: visible, gap: gap)
        #expect(zones.map(\.0.id) == ["primary", "sideTop", "sideBottom"])
        let primary = zones[0].1
        let top = zones[1].1
        let bottom = zones[2].1
        #expect(primary.maxX + 8 == top.x)
        #expect(top.maxX == bottom.maxX)
        #expect(bottom.y == 8)
        #expect(top.maxY == visible.maxY - 8)
        #expect(top.y == bottom.maxY + 8)
    }

    @Test("中央閱讀限寬 16:9 並置中")
    func centerReading() {
        let zones = LayoutTemplateCatalog.template(id: .centerReading)
            .resolvedZones(visible: visible, gap: gap)
        #expect(zones.count == 1)
        let rect = zones[0].1
        let innerH = 1424.0
        let expectedW = min(3424.0, innerH * 16 / 9)
        #expect(abs(rect.width - expectedW) < 0.5)
        #expect(abs(rect.midX - visible.midX) < 0.5)
        #expect(rect.height == innerH)
    }

    @Test("比例推薦：21:9 類與 32:9 類")
    func recommendations() {
        #expect(LayoutTemplateCatalog.recommended(aspectRatio: 3440.0 / 1440.0) == .centerStage)
        #expect(LayoutTemplateCatalog.secondaryRecommendation(aspectRatio: 3440.0 / 1440.0) == .threeColumns)
        #expect(LayoutTemplateCatalog.secondaryRecommendation(aspectRatio: 5120.0 / 1440.0) == .fourColumns)
    }

    @Test("分區矩形在可見範圍內且面積為正")
    func allTemplatesInside() {
        for id in LayoutTemplateID.allCases {
            let zones = LayoutTemplateCatalog.template(id: id)
                .resolvedZones(visible: visible, gap: 8)
            for (_, rect) in zones {
                #expect(rect.width > 0 && rect.height > 0)
                #expect(rect.x >= visible.x + 8 - 0.01)
                #expect(rect.maxX <= visible.maxX - 8 + 0.01)
            }
        }
    }
}
