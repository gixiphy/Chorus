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

    @Test("拖曳中放開 Shift 取消本趟，之後邊緣也不再吸")
    func shiftReleaseCancelsRestOfDrag() {
        var session = SnapDragSession()
        session.beginDrag(at: .milliseconds(0))
        let template = LayoutTemplateCatalog.template(id: .centerStage)
        let visible = LayoutRect(x: 0, y: 0, width: 3440, height: 1440)
        let ctx = SnapDragSession.ZoneContext(template: template, visible: visible, gap: 8)
        _ = session.updatePointer(
            x: 1720, y: 700, shiftDown: true, now: .milliseconds(200),
            edgeScreen: screen, zoneContext: ctx
        )
        let cancelled = session.updatePointer(
            x: 4, y: 450, shiftDown: false, now: .milliseconds(250),
            edgeScreen: screen, zoneContext: ctx
        )
        #expect(cancelled.preview == nil)
        #expect(session.isCancelled)
        let still = session.updatePointer(
            x: 4, y: 450, shiftDown: false, now: .milliseconds(500),
            edgeScreen: screen, zoneContext: nil
        )
        #expect(still.preview == nil)
        #expect(session.mouseUp(now: .milliseconds(510), shiftDown: false) == nil)
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
