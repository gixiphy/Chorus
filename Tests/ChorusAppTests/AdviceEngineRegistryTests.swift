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
        pending: Bool = false,
        probe: AdviceEngineRegistry.ProbeState = .ready(version: nil),
        auth: AdviceEngineRegistry.AuthState = .unknown
    ) -> AdviceEngineRegistry.DetectedEngine {
        AdviceEngineRegistry.DetectedEngine(
            engine: KnownCLIEngine(
                id: id, executableName: id, displayName: id,
                capabilities: capabilities,
                codec: .plainStdout, photoDelivery: .pathInPrompt,
                pendingIntegration: pending, experimental: false,
                readInstruction: "", loginCommand: id
            ),
            url: URL(fileURLWithPath: "/usr/bin/" + id),
            probe: probe,
            auth: auth
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

    @Test("available 只收可執行的：探測失敗的不列、待接入的不列")
    func availableFiltersUnrunnableAndPending() {
        let (registry, _) = makeRegistry()
        registry.injectDetected([
            fake("claude"),
            fake("broken", probe: .failed),
            fake("newcli", pending: true),
            fake("slow", probe: .pending),
        ])
        // .pending 也算可用：探測還沒回來就先列出，否則開設定頁會先閃一次空清單
        #expect(registry.available.map(\.id) == ["claude", "slow"])
        #expect(registry.unrunnable.map(\.id) == ["broken"])
    }

    @Test("探測失敗的引擎不會被選中，也不成為回落對象")
    func failedProbeNeverSelected() {
        let (registry, _) = makeRegistry(engineID: "broken")
        registry.injectDetected([fake("broken", probe: .failed), fake("grok")])
        #expect(registry.activeEngine?.id == "grok")
    }

    @Test("已知未登入的引擎不成為回落對象（換一家報未登入只是白等一次逾時）")
    func notLoggedInNeverFallback() {
        let (registry, _) = makeRegistry(engineID: "codex")
        registry.injectDetected([
            fake("claude", auth: .notLoggedIn),
            fake("grok", auth: .loggedIn),
        ])
        #expect(registry.activeEngine?.id == "grok")
    }

    @Test("使用者選定的引擎未登入時也不用它")
    func notLoggedInChosenFallsBack() {
        let (registry, _) = makeRegistry(engineID: "grok")
        registry.injectDetected([fake("claude"), fake("grok", auth: .notLoggedIn)])
        #expect(registry.activeEngine?.id == "claude")
    }

    @Test("auth 未知照常可用（沒有可靠查法的引擎不該被擋掉）")
    func unknownAuthStillUsable() {
        let (registry, _) = makeRegistry(engineID: "grok")
        registry.injectDetected([fake("grok", auth: .unknown)])
        #expect(registry.activeEngine?.id == "grok")
    }

    @Test("DetectedEngine.version 來自探測結果")
    func versionComesFromProbe() {
        let (registry, _) = makeRegistry()
        registry.injectDetected([
            fake("claude", probe: .ready(version: "2.1.273")),
            fake("grok", probe: .failed),
        ])
        #expect(registry.detected[0].version == "2.1.273")
        #expect(registry.detected[1].version == nil)
    }

    @Test("目錄：前六家順序與看圖能力不變")
    func catalogKeepsOriginalSix() {
        let ids = KnownCLIEngine.catalog.prefix(6).map(\.id)
        #expect(ids == ["claude", "agy", "grok", "codex", "opencode", "pi"])
        for engine in KnownCLIEngine.catalog.prefix(6) {
            #expect(engine.capabilities.contains(.vision), "\(engine.id) 少了 .vision")
            #expect(!engine.pendingIntegration)
        }
    }

    /// 本機實測通過（`scripts/verify-advice-engines.py`）的新引擎才拿掉實驗性標記。
    private static let verifiedNewEngines: Set<String> = ["cursor", "hermes"]

    @Test("目錄：新加的引擎一律純文字，未實測的標實驗性")
    func catalogNewEnginesArePlainText() {
        for engine in KnownCLIEngine.catalog.dropFirst(6) {
            #expect(engine.capabilities.isEmpty, "\(engine.id) 不該聲明看圖能力")
            #expect(engine.photoDelivery == .attached)
            #expect(!engine.pendingIntegration)
            if Self.verifiedNewEngines.contains(engine.id) {
                #expect(!engine.experimental, "\(engine.id) 已實測，不該標實驗性")
            } else {
                #expect(engine.experimental, "\(engine.id) 未實測，該標實驗性")
            }
        }
    }

    @Test("目錄：id 不重複，執行檔名也不重複")
    func catalogHasNoDuplicates() {
        let ids = KnownCLIEngine.catalog.map(\.id)
        #expect(Set(ids).count == ids.count)
        let executables = KnownCLIEngine.catalog.map(\.executableName)
        #expect(Set(executables).count == executables.count)
    }
}
