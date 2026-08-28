import Testing
@testable import Chorus

@Suite("模型清單解析")
struct ModelListingTests {
    @Test("opencode：每行一個 provider/model")
    func plainLines() {
        let models = AdviceEngineRegistry.parseModels("""
        opencode/big-pickle
        opencode-go/deepseek-v4-pro
        anthropic/claude-sonnet-4-6
        """, format: .plainLines)
        #expect(models == ["opencode/big-pickle", "opencode-go/deepseek-v4-pro", "anthropic/claude-sonnet-4-6"])
    }

    @Test("opencode：沒有斜線或帶空白的行是雜訊，濾掉")
    func plainLinesFiltersNoise() {
        let models = AdviceEngineRegistry.parseModels("""
        Fetching models...
        You are logged in.
        a/b
        some prose with / slash
        """, format: .plainLines)
        #expect(models == ["a/b"])
    }

    @Test("grok：只取項目符號行，並剝掉 (default) 尾註")
    func markerList() {
        let models = AdviceEngineRegistry.parseModels("""
        You are logged in with grok.com.

        Default model: grok-4.6

        Available models:
          * grok-4.6 (default)
          - grok-4.5
        """, format: .markerList)
        // "Default model: grok-4.6" 沒有項目符號，不該被當成一筆
        #expect(models == ["grok-4.6", "grok-4.5"])
    }

    @Test("空輸出回空陣列，不當成錯誤")
    func empty() {
        #expect(AdviceEngineRegistry.parseModels("", format: .plainLines).isEmpty)
        #expect(AdviceEngineRegistry.parseModels("", format: .markerList).isEmpty)
    }

    @Test("agy：TSV 取第一欄的 slug")
    func tabSeparated() {
        let models = AdviceEngineRegistry.parseModels("""
        Fetching available models...
        gemini-3.7-flash-high\tGemini 3.7 Flash (High)
        claude-sonnet-4-6\tClaude Sonnet 4.6 (Thinking)
        """, format: .tabSeparated)
        #expect(models == ["gemini-3.7-flash-high", "claude-sonnet-4-6"])
    }

    @Test("codex 快取：只取 visibility 為 list 的 slug")
    func codexCache() throws {
        let json = """
        {"fetched_at":"x","models":[
          {"slug":"gpt-5.6-terra","visibility":"list"},
          {"slug":"gpt-5.4-mini","visibility":"list"},
          {"slug":"legacy-thing","visibility":"hide"}
        ]}
        """
        let slugs = AdviceEngineRegistry.parseCodexModelsCache(Data(json.utf8))
        // 標 hide 的是 codex 自己不放進選單的，我們也不該列
        #expect(slugs == ["gpt-5.6-terra", "gpt-5.4-mini"])
    }

    @Test("codex 快取：缺 visibility 欄位時保守納入，不整份變空")
    func codexCacheMissingVisibility() {
        let json = #"{"models":[{"slug":"a"},{"slug":"b"}]}"#
        #expect(AdviceEngineRegistry.parseCodexModelsCache(Data(json.utf8)) == ["a", "b"])
    }

    @Test("codex 快取：檔案不存在或格式不符回空陣列，不當成錯誤")
    func codexCacheMalformed() {
        #expect(AdviceEngineRegistry.parseCodexModelsCache(Data("not json".utf8)).isEmpty)
        #expect(AdviceEngineRegistry.parseCodexModelsCache(Data("{}".utf8)).isEmpty)
    }

    @Test("五家都有模型清單來源")
    func everyEngineHasASource() {
        let byID = Dictionary(uniqueKeysWithValues: KnownCLIEngine.catalog.map { ($0.id, $0) })
        for id in ["agy", "grok", "opencode", "codex"] {
            #expect(byID[id]?.modelListing != nil, "\(id) 少了清單來源")
        }
        // claude 沒有列舉介面，但別名是設計上穩定的，可作靜態建議
        #expect(byID["claude"]?.modelListing == nil)
        #expect(byID["claude"]?.suggestedModels.contains("sonnet") == true)
    }

    @Test("每家都有模型欄位與格式提示——五家一致，不再有例外")
    func everyEngineHasModelField() {
        for engine in KnownCLIEngine.catalog {
            #expect(engine.supportsModelSelection, "\(engine.id) 少了模型欄位")
            #expect(!engine.modelHint.isEmpty, "\(engine.id) 少了格式提示")
        }
    }
}
