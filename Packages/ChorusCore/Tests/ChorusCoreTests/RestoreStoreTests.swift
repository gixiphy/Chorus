import Testing
@testable import ChorusCore

@Suite("RestoreStore")
struct RestoreStoreTests {
    @Test("第一次記住，連續排列不覆蓋，consume 後清除")
    func rememberAndConsume() {
        var store = RestoreStore()
        store.rememberOriginalIfNeeded(
            token: "w1",
            original: LayoutRect(x: 1, y: 2, width: 3, height: 4),
            displayUUID: "A",
            topologyGeneration: 1
        )
        store.rememberOriginalIfNeeded(
            token: "w1",
            original: LayoutRect(x: 9, y: 9, width: 9, height: 9),
            displayUUID: "B",
            topologyGeneration: 2
        )
        #expect(store.entry(for: "w1")?.original.x == 1)
        let entry = store.consume(token: "w1")
        #expect(entry?.displayUUID == "A")
        #expect(store.entry(for: "w1") == nil)
    }

    @Test("invalidate 清除還原鏈")
    func invalidate() {
        var store = RestoreStore()
        store.rememberOriginalIfNeeded(
            token: "w1",
            original: LayoutRect(x: 0, y: 0, width: 10, height: 10),
            displayUUID: "A",
            topologyGeneration: 1
        )
        store.invalidate(token: "w1")
        #expect(store.entry(for: "w1") == nil)
    }
}

@Suite("SnapResolver")
struct SnapResolverTests {
    private let resolver = SnapResolver()
    private let screen = SnapResolver.ScreenMetrics(
        frame: LayoutRect(x: 0, y: 0, width: 1600, height: 900),
        isLandscape: true
    )

    @Test("左緣中段 → 左半屏")
    func leftEdge() {
        let c = resolver.edgeCandidate(pointX: 4, pointY: 450, screen: screen)
        #expect(c?.action == .leftHalf)
    }

    @Test("左上角優先於左緣")
    func cornerBeatsEdge() {
        let c = resolver.edgeCandidate(pointX: 4, pointY: 880, screen: screen)
        #expect(c?.action == .topLeft)
    }

    @Test("Shift 分區命中中央主區")
    func zoneHit() {
        let template = LayoutTemplateCatalog.template(id: .centerStage)
        let visible = LayoutRect(x: 0, y: 0, width: 3440, height: 1440)
        let c = resolver.zoneCandidate(
            pointX: 1720,
            pointY: 700,
            template: template,
            visible: visible,
            gap: 8
        )
        #expect(c?.zoneID == "center")
        #expect(c?.templateID == .centerStage)
    }
}
