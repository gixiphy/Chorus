import Foundation
import Testing
@testable import ChorusCore

@Suite("UI translation prompt")
struct UITranslationPromptTests {
    @Test("prompt 帶目標語言、詞彙表與每一條的英文／繁中")
    func promptCarriesLanguageAndItems() {
        let items = [
            UITranslationItem(id: 0, key: "結束 Chorus", english: "Quit Chorus"),
            UITranslationItem(id: 1, key: "%lld 個動作", english: "%lld actions", plural: ["one": "%lld action", "other": "%lld actions"]),
        ]
        let prompt = UITranslationPrompt.prompt(items: items, targetLanguage: "Japanese")
        #expect(prompt.contains("Translate every item into Japanese"))
        #expect(prompt.contains("Chorus: product name, never translate"))
        #expect(prompt.contains("\"zh_Hant\": \"結束 Chorus\""))
        #expect(prompt.contains("\"en\": \"Quit Chorus\""))
        #expect(prompt.contains("\"plural_en\": {\"one\": \"%lld action\", \"other\": \"%lld actions\"}"))
        #expect(prompt.contains(UITranslationPrompt.schemaJSON))
    }

    @Test("輸入 JSON 逃逸引號、反斜線與換行，且是合法 JSON")
    func inputJSONIsValid() throws {
        let items = [UITranslationItem(id: 0, key: "說「你好」\\n", english: "Say \"hi\"\nnow")]
        let json = UITranslationPrompt.inputJSON(items)
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        let first = try #require(parsed?.first)
        #expect(first["en"] as? String == "Say \"hi\"\nnow")
        #expect(first["zh_Hant"] as? String == "說「你好」\\n")
    }

    @Test("schema 是合法 JSON 且與 UITranslationBatch 同形")
    func schemaShape() throws {
        let object = try JSONSerialization.jsonObject(with: Data(UITranslationPrompt.schemaJSON.utf8)) as? [String: Any]
        let properties = try #require(object?["properties"] as? [String: Any])
        #expect(properties.keys.contains("translations"))
    }

    @Test("批次回覆容錯：缺 translations 當空、多餘欄位忽略、text 與 plural 可缺")
    func batchDecoding() throws {
        let empty = try JSONDecoder().decode(UITranslationBatch.self, from: Data("{}".utf8))
        #expect(empty.translations.isEmpty)

        let json = """
        {"translations":[{"id":0,"text":"終了","extra":1},{"id":1,"plural":{"other":"%lld 件"}},{"id":2}]}
        """
        let batch = try JSONDecoder().decode(UITranslationBatch.self, from: Data(json.utf8))
        #expect(batch.translations.count == 3)
        #expect(batch.translations[0].text == "終了")
        #expect(batch.translations[1].plural?["other"] == "%lld 件")
        #expect(batch.translations[2].text == nil && batch.translations[2].plural == nil)
    }
}

@Suite("UI translation validator")
struct UITranslationValidatorTests {
    @Test("specifier 正規化：去位置編號、忽略 %%、不吃空白旗標")
    func specifiers() {
        #expect(UITranslationValidator.normalizedSpecifiers("%1$@ → %2$lld") == ["%@", "%lld"])
        #expect(UITranslationValidator.normalizedSpecifiers("亮度 %lld%%") == ["%lld"])
        #expect(UITranslationValidator.normalizedSpecifiers("Gain above 100% passes") == [])
        #expect(UITranslationValidator.normalizedSpecifiers("剩餘 %d:%02d") == ["%02d", "%d"])
    }

    @Test("接受：specifier 一致；拒絕：空白、數量或型別不符")
    func acceptance() {
        #expect(UITranslationValidator.isAcceptable(candidate: "「%@」を終了", source: "Quit \"%@\""))
        #expect(UITranslationValidator.isAcceptable(candidate: "%2$@ の %1$@", source: "%@ of %@"))
        #expect(!UITranslationValidator.isAcceptable(candidate: "   ", source: "Quit"))
        #expect(!UITranslationValidator.isAcceptable(candidate: "%@ 件", source: "%lld items"))
        #expect(!UITranslationValidator.isAcceptable(candidate: "完了", source: "Restored %lld items"))
    }
}
