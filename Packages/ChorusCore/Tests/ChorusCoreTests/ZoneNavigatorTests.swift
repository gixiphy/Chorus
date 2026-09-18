import Testing
@testable import ChorusCore

@Suite("ZoneNavigator")
struct ZoneNavigatorTests {
    @Test("中央主區：焦點預設 center，左右移動")
    func centerStageNav() {
        let zones = LayoutTemplateCatalog.template(id: .centerStage).zones
        var nav = ZoneNavigator(zones: zones)
        #expect(nav.focusedID == "center")
        nav.move(.left)
        #expect(nav.focusedID == "left")
        nav.move(.right)
        #expect(nav.focusedID == "center")
        nav.move(.right)
        #expect(nav.focusedID == "right")
        nav.move(.right)
        #expect(nav.focusedID == "right")
    }

    @Test("三欄無主區時焦點第 1 區")
    func threeColumnsStartsFirst() {
        let zones = LayoutTemplateCatalog.template(id: .threeColumns).zones
        var nav = ZoneNavigator(zones: zones)
        #expect(nav.focusedID == "col1")
        nav.move(.right)
        #expect(nav.focusedID == "col2")
    }

    @Test("主區＋雙側窗：上下在側欄間移動")
    func primaryStackVertical() {
        let zones = LayoutTemplateCatalog.template(id: .primaryStack).zones
        var nav = ZoneNavigator(zones: zones)
        #expect(nav.focusedID == "primary")
        nav.move(.right)
        #expect(nav.focusedID == "sideTop" || nav.focusedID == "sideBottom")
        let side = nav.focusedID!
        nav.move(.down)
        #expect(nav.focusedID != side || zones.count == 1)
        // 從 primary 右移到側欄後，上下應在 sideTop/sideBottom 之間
        nav = ZoneNavigator(zones: zones, focusedID: "sideTop")
        nav.move(.down)
        #expect(nav.focusedID == "sideBottom")
        nav.move(.up)
        #expect(nav.focusedID == "sideTop")
        nav.move(.left)
        #expect(nav.focusedID == "primary")
    }
}
