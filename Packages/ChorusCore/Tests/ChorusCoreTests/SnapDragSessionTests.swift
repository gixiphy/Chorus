import Testing
@testable import ChorusCore

@Suite("SnapDragSession")
struct SnapDragSessionTests {
    private let resolver = SnapResolver()
    private let screen = SnapResolver.ScreenMetrics(
        frame: LayoutRect(x: 0, y: 0, width: 1600, height: 900),
        isLandscape: true
    )

    @Test("進入熱區未滿 dwell 不穩定；滿 150ms 後穩定")
    func dwellBeforeStable() {
        var session = SnapDragSession()
        session.beginDrag(at: .milliseconds(0))
        let early = session.updatePointer(
            x: 4,
            y: 450,
            shiftDown: false,
            now: .milliseconds(0),
            edgeScreen: screen,
            zoneContext: nil
        )
        #expect(early.preview != nil)
        #expect(early.isStable == false)

        let mid = session.updatePointer(
            x: 4,
            y: 450,
            shiftDown: false,
            now: .milliseconds(100),
            edgeScreen: screen,
            zoneContext: nil
        )
        #expect(mid.isStable == false)

        let ready = session.updatePointer(
            x: 4,
            y: 450,
            shiftDown: false,
            now: .milliseconds(150),
            edgeScreen: screen,
            zoneContext: nil
        )
        #expect(ready.isStable)
        #expect(ready.preview?.action == .leftHalf)
    }

    @Test("放開時未穩定不提交")
    func releaseBeforeDwellDoesNotCommit() {
        var session = SnapDragSession()
        session.beginDrag(at: .milliseconds(0))
        _ = session.updatePointer(
            x: 4, y: 450, shiftDown: false, now: .milliseconds(40),
            edgeScreen: screen, zoneContext: nil
        )
        let commit = session.mouseUp(now: .milliseconds(50), shiftDown: false)
        #expect(commit == nil)
    }

    @Test("Shift 模式互斥：有 zone 時不回傳邊緣")
    func shiftExcludesEdge() {
        var session = SnapDragSession()
        session.beginDrag(at: .milliseconds(0))
        let template = LayoutTemplateCatalog.template(id: .centerStage)
        let visible = LayoutRect(x: 0, y: 0, width: 3440, height: 1440)
        let ctx = SnapDragSession.ZoneContext(template: template, visible: visible, gap: 8)
        _ = session.updatePointer(
            x: 1720, y: 700, shiftDown: true, now: .milliseconds(0),
            edgeScreen: screen, zoneContext: ctx
        )
        let result = session.updatePointer(
            x: 1720, y: 700, shiftDown: true, now: .milliseconds(150),
            edgeScreen: screen, zoneContext: ctx
        )
        #expect(result.preview?.zoneID == "center")
        #expect(result.preview?.action == nil)
        #expect(result.isStable)
    }

    @Test("放開 Shift 立即回到基本型，不整趟作廢")
    func shiftReleaseReturnsToBasic() {
        var session = SnapDragSession()
        session.beginDrag(at: .milliseconds(0))
        let template = LayoutTemplateCatalog.template(id: .centerStage)
        let visible = LayoutRect(x: 0, y: 0, width: 1600, height: 900)
        let ctx = SnapDragSession.ZoneContext(template: template, visible: visible, gap: 8)
        let zone = session.updatePointer(
            x: 800, y: 450, shiftDown: true, now: .milliseconds(200),
            edgeScreen: screen, zoneContext: ctx
        )
        #expect(zone.preview?.zoneID == "center")
        let released = session.updatePointer(
            x: 800, y: 450, shiftDown: false, now: .milliseconds(250),
            edgeScreen: screen, zoneContext: nil
        )
        #expect(released.preview == nil)
        #expect(!session.isCancelled)
        _ = session.updatePointer(
            x: 4, y: 450, shiftDown: false, now: .milliseconds(300),
            edgeScreen: screen, zoneContext: nil
        )
        let edge = session.updatePointer(
            x: 4, y: 450, shiftDown: false, now: .milliseconds(460),
            edgeScreen: screen, zoneContext: nil
        )
        #expect(edge.preview?.action == .leftHalf)
        #expect(edge.isStable)
        #expect(session.mouseUp(now: .milliseconds(470), shiftDown: false)?.action == .leftHalf)
    }

    @Test("上一趟用過 Shift，下一趟不按 Shift 仍是基本型（模式不殘留）")
    func shiftDoesNotStickAcrossDrags() {
        var session = SnapDragSession()
        let template = LayoutTemplateCatalog.template(id: .centerStage)
        let visible = LayoutRect(x: 0, y: 0, width: 1600, height: 900)
        let ctx = SnapDragSession.ZoneContext(template: template, visible: visible, gap: 8)

        session.beginDrag(at: .milliseconds(0))
        _ = session.updatePointer(
            x: 800, y: 450, shiftDown: true, now: .milliseconds(0),
            edgeScreen: screen, zoneContext: ctx
        )
        #expect(session.mouseUp(now: .milliseconds(200), shiftDown: true)?.zoneID == "center")

        session.beginDrag(at: .milliseconds(1000))
        _ = session.updatePointer(
            x: 1596, y: 450, shiftDown: false, now: .milliseconds(1000),
            edgeScreen: screen, zoneContext: nil
        )
        let second = session.updatePointer(
            x: 1596, y: 450, shiftDown: false, now: .milliseconds(1200),
            edgeScreen: screen, zoneContext: nil
        )
        #expect(!session.isCancelled)
        #expect(second.preview?.action == .rightHalf)
        #expect(session.mouseUp(now: .milliseconds(1210), shiftDown: false)?.action == .rightHalf)
    }

    @Test("基本型下緣＝下半屏；按住 Shift 才是三分特型")
    func bottomEdgeDependsOnShift() {
        var session = SnapDragSession()
        session.beginDrag(at: .milliseconds(0))
        let basic = session.updatePointer(
            x: 800, y: 4, shiftDown: false, now: .milliseconds(0),
            edgeScreen: screen, zoneContext: nil
        )
        #expect(basic.preview?.action == .bottomHalf)
        let special = session.updatePointer(
            x: 800, y: 4, shiftDown: true, now: .milliseconds(10),
            edgeScreen: screen, zoneContext: nil
        )
        #expect(special.preview?.action == .centerThird)
        #expect(!special.isStable)
    }

    @Test("按住 Shift 時下緣特型優先於分區")
    func shiftBottomEdgeBeatsZones() {
        var session = SnapDragSession()
        session.beginDrag(at: .milliseconds(0))
        let template = LayoutTemplateCatalog.template(id: .centerStage)
        let visible = LayoutRect(x: 0, y: 0, width: 1600, height: 900)
        let ctx = SnapDragSession.ZoneContext(template: template, visible: visible, gap: 8)
        let result = session.updatePointer(
            x: 500, y: 4, shiftDown: true, now: .milliseconds(0),
            edgeScreen: screen, zoneContext: ctx
        )
        #expect(result.preview?.action == .leftTwoThirds)
        #expect(result.preview?.zoneID == nil)
    }

    @Test("候選穩定後才換模式就放開滑鼠：不提交")
    func modeMismatchAtMouseUpDoesNotCommit() {
        var session = SnapDragSession()
        session.beginDrag(at: .milliseconds(0))
        _ = session.updatePointer(
            x: 800, y: 4, shiftDown: true, now: .milliseconds(0),
            edgeScreen: screen, zoneContext: nil
        )
        #expect(session.mouseUp(now: .milliseconds(300), shiftDown: false) == nil)
    }

    @Test("Escape 取消本趟")
    func escapeCancels() {
        var session = SnapDragSession()
        session.beginDrag(at: .milliseconds(0))
        _ = session.updatePointer(
            x: 4, y: 450, shiftDown: false, now: .milliseconds(200),
            edgeScreen: screen, zoneContext: nil
        )
        session.cancel()
        #expect(session.isCancelled)
        #expect(session.mouseUp(now: .milliseconds(210), shiftDown: false) == nil)
    }

    @Test("換候選重計 dwell")
    func candidateChangeResetsDwell() {
        var session = SnapDragSession()
        session.beginDrag(at: .milliseconds(0))
        _ = session.updatePointer(
            x: 4, y: 450, shiftDown: false, now: .milliseconds(200),
            edgeScreen: screen, zoneContext: nil
        )
        let switched = session.updatePointer(
            x: 1596, y: 450, shiftDown: false, now: .milliseconds(210),
            edgeScreen: screen, zoneContext: nil
        )
        #expect(switched.preview?.action == .rightHalf)
        #expect(switched.isStable == false)
        let stable = session.updatePointer(
            x: 1596, y: 450, shiftDown: false, now: .milliseconds(370),
            edgeScreen: screen, zoneContext: nil
        )
        #expect(stable.isStable)
    }
}
