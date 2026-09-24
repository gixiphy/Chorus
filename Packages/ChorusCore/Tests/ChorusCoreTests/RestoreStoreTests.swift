import Foundation
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

    @Test("beginGroup 後 group(containing:) 找得到每個 token")
    func groupLookup() {
        var store = RestoreStore()
        let id = UUID()
        store.beginGroup(id: id, tokens: ["w1", "w2"], displayUUID: "A", topologyGeneration: 1)
        #expect(store.group(id: id)?.tokens == ["w1", "w2"])
        #expect(store.group(containing: "w1")?.id == id)
        #expect(store.group(containing: "w2")?.id == id)
    }

    @Test("consume 只從群組移除該 token；最後一個消掉後群組刪除")
    func consumeShrinksGroup() {
        var store = RestoreStore()
        let id = UUID()
        for token in ["w1", "w2"] {
            store.rememberOriginalIfNeeded(
                token: token,
                original: LayoutRect(x: 0, y: 0, width: 10, height: 10),
                displayUUID: "A",
                topologyGeneration: 1,
                groupID: id
            )
        }
        store.beginGroup(id: id, tokens: ["w1", "w2"], displayUUID: "A", topologyGeneration: 1)
        _ = store.consume(token: "w1")
        #expect(store.group(id: id)?.tokens == ["w2"])
        _ = store.consume(token: "w2")
        #expect(store.group(id: id) == nil)
    }

    @Test("invalidate 只影響該 token")
    func invalidateOneMember() {
        var store = RestoreStore()
        let id = UUID()
        for token in ["w1", "w2"] {
            store.rememberOriginalIfNeeded(
                token: token,
                original: LayoutRect(x: 0, y: 0, width: 10, height: 10),
                displayUUID: "A",
                topologyGeneration: 1,
                groupID: id
            )
        }
        store.beginGroup(id: id, tokens: ["w1", "w2"], displayUUID: "A", topologyGeneration: 1)
        store.invalidate(token: "w1")
        #expect(store.entry(for: "w1") == nil)
        #expect(store.entry(for: "w2") != nil)
        #expect(store.group(id: id)?.tokens == ["w2"])
    }

    @Test("noteApplied 更新 expectedFrame 但不覆蓋 original")
    func noteAppliedKeepsOriginal() {
        var store = RestoreStore()
        let original = LayoutRect(x: 1, y: 2, width: 3, height: 4)
        store.rememberOriginalIfNeeded(
            token: "w1",
            original: original,
            displayUUID: "A",
            topologyGeneration: 1
        )
        let after = LayoutRect(x: 10, y: 20, width: 30, height: 40)
        store.noteApplied(token: "w1", after: after)
        #expect(store.entry(for: "w1")?.original == original)
        #expect(store.entry(for: "w1")?.expectedFrame == after)
    }

    @Test("±2pt 內 false、超過 true、沒有 expectedFrame 視為 true")
    func userMovedTolerance() {
        var store = RestoreStore()
        store.rememberOriginalIfNeeded(
            token: "w1",
            original: LayoutRect(x: 0, y: 0, width: 100, height: 100),
            displayUUID: "A",
            topologyGeneration: 1
        )
        #expect(store.isUserMoved(token: "w1", current: LayoutRect(x: 0, y: 0, width: 100, height: 100)))

        store.noteApplied(token: "w1", after: LayoutRect(x: 10, y: 10, width: 100, height: 100))
        #expect(!store.isUserMoved(token: "w1", current: LayoutRect(x: 12, y: 10, width: 100, height: 100)))
        #expect(store.isUserMoved(token: "w1", current: LayoutRect(x: 13, y: 10, width: 100, height: 100)))
    }

    @Test("同 token 再次入組：original 不變、groupID 換新、舊群組不含它")
    func rejoinGroup() {
        var store = RestoreStore()
        let oldID = UUID()
        let newID = UUID()
        let original = LayoutRect(x: 1, y: 2, width: 3, height: 4)
        store.rememberOriginalIfNeeded(
            token: "w1",
            original: original,
            displayUUID: "A",
            topologyGeneration: 1,
            groupID: oldID
        )
        store.beginGroup(id: oldID, tokens: ["w1", "w2"], displayUUID: "A", topologyGeneration: 1)
        store.rememberOriginalIfNeeded(
            token: "w1",
            original: LayoutRect(x: 9, y: 9, width: 9, height: 9),
            displayUUID: "B",
            topologyGeneration: 2,
            groupID: newID
        )
        store.beginGroup(id: newID, tokens: ["w1"], displayUUID: "B", topologyGeneration: 2)
        #expect(store.entry(for: "w1")?.original == original)
        #expect(store.entry(for: "w1")?.groupID == newID)
        #expect(store.group(id: oldID)?.tokens.contains("w1") != true)
        #expect(store.group(id: newID)?.tokens == ["w1"])
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
