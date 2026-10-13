import Foundation
import Testing
@testable import Chorus

/// 合併模式的動態狀態句（`KeepAwakeWorkStatusFormatter`）在外語環境不能回退成繁中模板。
@Suite("KeepAwake merged status localization")
struct KeepAwakeMergedLocalizationTests {
    private static let dynamicKeys = [
        "%@ 工作中＋%@ — %@",
        "%@ 工作中 — %@",
        "%@ 高負載 — %@",
        "螢幕與系統不待機",
    ]

    private static func placeholderCount(_ text: String) -> Int {
        text.components(separatedBy: "%@").count - 1
    }

    @Test("編譯後的 en.lproj 含四個動態狀態句，placeholder 數量一致")
    func englishResourceCoversDynamicCaptions() {
        let strings = UITranslationStore.builtinSource().strings
        for key in Self.dynamicKeys {
            let value = strings[key]
            #expect(value != nil, "en 缺少：\(key)")
            if let value {
                #expect(value != key, "en 與原文相同（未翻譯）：\(key)")
                #expect(Self.placeholderCount(value) == Self.placeholderCount(key), "en placeholder 不一致：\(key)")
            }
        }
    }

    @Test("Localizable.xcstrings 的四個動態狀態句有 en 與 zh-Hans，且已翻譯")
    func catalogCoversEnglishAndSimplifiedChinese() throws {
        let catalog = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Chorus/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: catalog)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(root["strings"] as? [String: Any])
        for key in Self.dynamicKeys {
            let entry = try #require(strings[key] as? [String: Any], "xcstrings 缺 key：\(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in ["en", "zh-Hans"] {
                let unit = (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any]
                #expect(unit?["state"] as? String == "translated", "\(language) 未翻譯：\(key)")
                let value = unit?["value"] as? String ?? ""
                #expect(!value.isEmpty, "\(language) 空白：\(key)")
                #expect(Self.placeholderCount(value) == Self.placeholderCount(key), "\(language) placeholder 不一致：\(key)")
            }
        }
    }
}
