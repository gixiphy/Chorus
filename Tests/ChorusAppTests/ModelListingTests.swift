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

    @Test("目錄裡宣告有列舉的引擎，其參數與格式符合實測")
    func catalogListings() {
        let byID = Dictionary(uniqueKeysWithValues: KnownCLIEngine.catalog.map { ($0.id, $0) })
        #expect(byID["opencode"]?.modelListing?.arguments == ["models"])
        #expect(byID["grok"]?.modelListing?.arguments == ["models"])
        // agy models 實測會卡死、codex 沒有非互動列舉指令：兩者都不宣告
        #expect(byID["agy"]?.modelListing == nil)
        #expect(byID["codex"]?.modelListing == nil)
        // claude 沒有列舉指令，但別名是設計上穩定的，可作靜態建議
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
