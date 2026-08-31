import ChorusCore
import Foundation
import Testing
@testable import Chorus

/// 音訊調音顧問：fake provider 走完整管線（context → sanitize → result →
/// 套用 → 還原）。CLI 引擎不在測試範圍（registry 傳 nil）。
@MainActor
@Suite("Audio tuning advisor")
struct AudioTuningAdvisorTests {
    private func makeStack() -> (AudioTuningAdvisor, TapEngine, AUEffectCatalog, SettingsStore) {
        let backend = FakeTapBackend()
        let registry = AudioProcessRegistry()
        registry.injectFake([
            .init(objectID: 1001, pid: 2001, bundleID: "com.apple.podcasts", name: "Podcast", isAudible: true),
        ])
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "tuner-\(UUID().uuidString)")!)
        let engine = TapEngine(backend: backend, registry: registry, settings: settings)
        let catalog = AUEffectCatalog()
        catalog.refresh() // 真的掃（不實例化，永遠安全）——建鏈條目要真 key
        let advisor = AudioTuningAdvisor(
            settings: settings, registry: nil,
            tapEngine: engine, audioManager: nil, catalog: catalog
        )
        return (advisor, engine, catalog, settings)
    }

    private func waitForResult(_ advisor: AudioTuningAdvisor) async throws {
        for _ in 0..<100 {
            if advisor.result != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("注入建議走完整管線：sanitize 後進 result（編造的效果被濾掉）")
    func injectRunsTheFullPipeline() async throws {
        // advisor 只持弱參照——engine 要在測試裡活著，context 才查得到名稱
        let (advisor, engine, catalog, _) = makeStack()
        defer { _ = engine }
        let realKey = try #require(catalog.items.first?.component.key)
        let json = """
        {"summary":"人聲優先","eq":{"bandsGainDB":[0,0,0,2,4,4,2,0,0,0],"reason":"拱中頻"},
         "effects":[{"componentKey":"\(realKey)","name":"亂寫","reason":"r"},
                    {"componentKey":"fake-fake-fake","name":"編造","reason":"r"}],
         "warnings":["w"]}
        """
        advisor.debugInject(target: .app(bundleID: "com.apple.podcasts"), adviceJSON: json)
        try await waitForResult(advisor)

        let result = try #require(advisor.result)
        #expect(result.advice.eq?.bandsGainDB[4] == 4)
        #expect(result.advice.effects.count == 1) // 編造的被 sanitize 濾掉
        #expect(result.advice.effects[0].componentKey == realKey)
        #expect(result.context.targetName == "Podcast")
    }

    @Test("套用：EQ 進 App 設定（sourceName＝AI 建議）、效果鏈建立；還原回原狀")
    func applyWritesThroughAndUndoRestores() async throws {
        let (advisor, engine, catalog, _) = makeStack()
        let realKey = try #require(catalog.items.first?.component.key)
        // 先有一組使用者自己的 EQ——還原要回到它，不是回到空白
        var original = EQSettings.tenBandDefault()
        original.bands[0].gainDB = -3
        engine.setAppEQ(original, bundleID: "com.apple.podcasts")

        let json = """
        {"summary":"s","eq":{"bandsGainDB":[0,0,0,3,3,0,0,0,0,0],"reason":"r"},
         "effects":[{"componentKey":"\(realKey)","name":"n","reason":"r"}],"warnings":[]}
        """
        advisor.debugInject(target: .app(bundleID: "com.apple.podcasts"), adviceJSON: json)
        try await waitForResult(advisor)
        advisor.debugApply()

        let applied = engine.setting(for: "com.apple.podcasts")
        #expect(applied.eq?.sourceName == "AI 建議")
        #expect(applied.eq?.bands[3].gainDB == 3)
        #expect(applied.effects.count == 1)
        #expect(applied.effects[0].component.key == realKey)
        #expect(advisor.canUndo)

        advisor.undoLastApply()
        let restored = engine.setting(for: "com.apple.podcasts")
        #expect(restored.eq == original)
        #expect(restored.effects.isEmpty)
        #expect(!advisor.canUndo)
    }

    @Test("模型沒建議的部分不碰：只有效果建議時，使用者的 EQ 原樣留著")
    func applyOnlyTouchesWhatWasSuggested() async throws {
        let (advisor, engine, catalog, _) = makeStack()
        let realKey = try #require(catalog.items.first?.component.key)
        var original = EQSettings.tenBandDefault()
        original.bands[9].gainDB = 5
        engine.setAppEQ(original, bundleID: "com.apple.podcasts")

        let json = """
        {"summary":"s","effects":[{"componentKey":"\(realKey)","name":"n","reason":"r"}],"warnings":[]}
        """
        advisor.debugInject(target: .app(bundleID: "com.apple.podcasts"), adviceJSON: json)
        try await waitForResult(advisor)
        advisor.debugApply()

        #expect(engine.setting(for: "com.apple.podcasts").eq == original)
        #expect(engine.setting(for: "com.apple.podcasts").effects.count == 1)
    }

    @Test("context 組裝：目標身分、可用 AU 與現行設定摘要都在")
    func contextCarriesTargetAndCatalog() {
        let (advisor, engine, catalog, _) = makeStack()
        engine.setGain(0.5, bundleID: "com.apple.podcasts") // 有調整，但 EQ 沒開
        let context = advisor.buildContext(
            target: .app(bundleID: "com.apple.podcasts"), request: "需求"
        )
        #expect(context.targetKind == "app")
        #expect(context.targetName == "Podcast")
        #expect(context.request == "需求")
        #expect(context.bandFrequencies.count == 10)
        #expect(context.availableEffects.count == catalog.items.count)
        #expect(context.currentEQDescription.isEmpty) // EQ 沒生效就不描述
    }

    @Test("沒有引擎時 analyze 誠實報錯並給開設定的 assist")
    func missingEngineFailsHonestly() {
        let (advisor, _, _, _) = makeStack()
        advisor.analyze(target: .app(bundleID: "com.apple.podcasts"), request: "")
        #expect(advisor.lastErrorMessage?.contains("分析引擎") == true)
        #expect(advisor.lastErrorAssist == .openEngineSettings)
    }
}
