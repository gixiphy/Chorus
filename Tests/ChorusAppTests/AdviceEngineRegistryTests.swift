import Foundation
import Testing
@testable import Chorus

/// 引擎選擇邏輯（E0：能力旗標＋啟用開關＋回落）。
/// 全部走 `scanOnInit: false`＋`injectDetected`，不掃描實機、不 spawn 行程。
@MainActor
@Suite("分析引擎 Registry")
struct AdviceEngineRegistryTests {
    private func makeRegistry(
        engineID: String = "claude",
        disabled: Set<String> = []
    ) -> (registry: AdviceEngineRegistry, defaults: UserDefaults) {
        let defaults = UserDefaults(suiteName: "engine-reg-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.advisorEngineID = engineID
        settings.advisorDisabledEngines = disabled
        return (AdviceEngineRegistry(settings: settings, scanOnInit: false), defaults)
    }

    private func fake(
        _ id: String,
        capabilities: Set<KnownCLIEngine.Capability> = [.vision],
        pending: Bool = false
    ) -> AdviceEngineRegistry.DetectedEngine {
        AdviceEngineRegistry.DetectedEngine(
            engine: KnownCLIEngine(
                id: id, executableName: id, displayName: id,
                capabilities: capabilities,
                codec: .plainStdout, photoDelivery: .pathInPrompt,
                pendingIntegration: pending, experimental: false,
                supportsModelSelection: false, modelHint: "",
                modelListing: nil, suggestedModels: [],
                readInstruction: "", loginCommand: id
            ),
            url: URL(fileURLWithPath: "/usr/bin/" + id),
            version: nil
        )
    }

    @Test("選定引擎具備所需能力時直接用它")
    func chosenEngineWins() {
        let (registry, _) = makeRegistry(engineID: "grok")
        registry.injectDetected([fake("claude"), fake("grok")])
        #expect(registry.activeEngine(requiring: [.vision])?.id == "grok")
    }

    @Test("選定的純文字引擎：調音顧問可用、光環境顧問回落 claude")
    func capabilityFiltering() {
        let (registry, _) = makeRegistry(engineID: "textonly")
        registry.injectDetected([fake("claude"), fake("textonly", capabilities: [])])
        // 不要求能力（調音顧問）：尊重使用者選擇
        #expect(registry.activeEngine?.id == "textonly")
        // 要求 vision（光環境顧問）：選定的不合格，回落 claude
        #expect(registry.activeEngine(requiring: [.vision])?.id == "claude")
    }

    @Test("停用的引擎不被使用：選定被停用時回落")
    func disabledChosenFallsBack() {
        let (registry, _) = makeRegistry(engineID: "grok", disabled: ["grok"])
        registry.injectDetected([fake("claude"), fake("grok")])
        #expect(registry.activeEngine?.id == "claude")
    }

    @Test("停用的引擎也不成為回落對象")
    func disabledNeverFallback() {
        // 選定的 codex 未偵測到；claude 又被停用——只能落到 grok
        let (registry, _) = makeRegistry(engineID: "codex", disabled: ["claude"])
        registry.injectDetected([fake("claude"), fake("grok")])
        #expect(registry.activeEngine?.id == "grok")
    }

    @Test("全部停用時回 nil（顧問按鈕停用，不硬 spawn）")
    func allDisabled() {
        let (registry, _) = makeRegistry(disabled: ["claude", "grok"])
        registry.injectDetected([fake("claude"), fake("grok")])
        #expect(registry.activeEngine == nil)
    }

    @Test("待接入引擎照舊不可選")
    func pendingIntegrationExcluded() {
        let (registry, _) = makeRegistry(engineID: "newcli")
        registry.injectDetected([fake("claude"), fake("newcli", pending: true)])
        #expect(registry.activeEngine?.id == "claude")
    }

    @Test("setEnabled 落盤：同一 defaults 重建後停用狀態仍在")
    func enablePersists() {
        let (registry, defaults) = makeRegistry()
        registry.injectDetected([fake("claude"), fake("grok")])
        registry.setEnabled(false, engineID: "grok")
        #expect(!registry.isEnabled("grok"))
        // 重建 SettingsStore（模擬重啟）
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.advisorDisabledEngines == ["grok"])
        // 開回來
        registry.setEnabled(true, engineID: "grok")
        #expect(registry.isEnabled("grok"))
        #expect(SettingsStore(defaults: defaults).advisorDisabledEngines.isEmpty)
    }
}
