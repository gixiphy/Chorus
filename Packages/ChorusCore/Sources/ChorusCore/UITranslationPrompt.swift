import Foundation

/// 使用者自翻介面語言（DESIGN-20260902-user-cli-translation）的 prompt、
/// 回覆型別與驗證。純字串組裝、可快照測試；CLI 呼叫在 app 層。
///
/// 詞彙表與風格規則與 `scripts/translate-strings.py`（產內建英文的那支）同源：
/// 人翻的英文與機翻的其他語言要對得上同一組術語。

/// 一條待翻的介面字串。`key` 是繁中原文（catalog key），`english` 是內建英文，
/// 兩者都給模型；英文是主要來源，繁中是第二參考。
public struct UITranslationItem: Sendable, Equatable {
    public var id: Int
    public var key: String
    public var english: String?
    /// 複數形（`one`／`other` → 英文）。有就要求模型回複數物件。
    public var plural: [String: String]?

    public init(id: Int, key: String, english: String? = nil, plural: [String: String]? = nil) {
        self.id = id
        self.key = key
        self.english = english
        self.plural = plural
    }
}

/// 模型回的一批翻譯。缺欄位當空、多欄位忽略——一批裡壞一條不該讓整批作廢。
public struct UITranslationBatch: Decodable, Sendable, Equatable {
    public struct Entry: Decodable, Sendable, Equatable {
        public var id: Int
        public var text: String?
        public var plural: [String: String]?

        public init(id: Int, text: String? = nil, plural: [String: String]? = nil) {
            self.id = id
            self.text = text
            self.plural = plural
        }
    }

    public var translations: [Entry]

    public init(translations: [Entry]) {
        self.translations = translations
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        translations = try container.decodeIfPresent([Entry].self, forKey: .translations) ?? []
    }

    private enum CodingKeys: String, CodingKey { case translations }
}

public enum UITranslationPrompt {
    /// 產品詞彙表：原文 → 建議譯法／說明。給模型看，不翻詞彙表本身。
    public static let glossary: [(term: String, meaning: String)] = [
        ("Chorus", "product name, never translate"),
        ("場景 / scene", "a saved set of brightness/volume actions"),
        ("限時場景 / timed scene", "a scene applied for a limited time, then restored"),
        ("專注 / focus", "the timed-scene feature"),
        ("跨機 / cross-machine", "on another paired Mac"),
        ("配對 / pair", "pairing two Macs"),
        ("螢幕、顯示器 / display", "the display hardware"),
        ("軟體調光 / software dimming", "gamma-based dimming"),
        ("自動亮度 / auto-brightness", "brightness follows the ambient light sensor"),
        ("螢幕長亮 / Keep Awake", "prevents display (and optionally system) sleep"),
        ("各 App 音量 / per-app volume", "independent volume per application"),
        ("App 音訊接管 / App audio takeover", "routing app audio through Chorus"),
        ("效果鏈 / effect chain", "a chain of Audio Unit effects"),
        ("等化 / EQ", "equalizer"),
        ("前置增益 / preamp", "pre-amplification gain"),
        ("校正檔 / correction profile", "an AutoEq headphone correction"),
        ("轉送 / forward", "forwarding volume changes to another device"),
        ("鏡射 / mirror", "mirroring volume to a device's own control"),
        ("排除 / exclude", "leaving a device or app untouched by Chorus"),
        ("配置圖 / layout", "the desk layout diagram"),
        ("情境 / scenario", "a saved desk lighting scenario"),
        ("分析引擎 / analysis engine", "an external AI CLI such as Claude Code"),
        ("還原 / restore", "putting values back after a timed scene"),
        ("選單列 / menu bar", "the macOS menu bar"),
        ("系統設定 / System Settings", "use the target OS's official name"),
        ("隱私權與安全性 / Privacy & Security", "use the target OS's official name"),
        ("螢幕與系統音訊錄製 / Screen & System Audio Recording", "use the target OS's official name"),
        ("輔助使用 / Accessibility", "use the target OS's official name"),
    ]

    /// 給 `--json-schema` 類引擎的輸出 schema；與 `UITranslationBatch` 同形。
    public static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "translations": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "id": { "type": "integer" },
              "text": { "type": "string" },
              "plural": {
                "type": "object",
                "additionalProperties": { "type": "string" }
              }
            },
            "required": ["id"]
          }
        }
      },
      "required": ["translations"]
    }
    """

    /// 一批字串的完整 prompt。`targetLanguage` 用英文語言名（"Japanese"）。
    public static func prompt(items: [UITranslationItem], targetLanguage: String) -> String {
        let glossaryLines = glossary.map { "- \($0.term): \($0.meaning)" }.joined(separator: "\n")
        return """
        You are localizing the user interface of Chorus, a macOS menu bar app that controls display \
        brightness, audio output volume, per-app volume and EQ, keep-awake timers and cross-machine \
        scenes across paired Macs. Translate every item into \(targetLanguage).

        Each item has "en" (the English UI text, your primary source) and "zh_Hant" (the original \
        Traditional Chinese, a second reference when the English is ambiguous). Items with "plural_en" \
        are count-based strings: return a "plural" object with the CLDR plural categories \
        \(targetLanguage) needs (at least "other"; add "one", "two", "few", "many", "zero" only when \
        the language distinguishes them).

        Glossary:
        \(glossaryLines)

        Rules:
        - Follow Apple's macOS Human Interface Guidelines conventions for \(targetLanguage): use the \
        official \(targetLanguage) names of macOS features and System Settings panes.
        - Keep it compact: the menu bar popover is narrow. Short labels must stay short; never add \
        words that are not in the source.
        - Keep every format specifier exactly (%@, %lld, %d, %02d, %1$@ …), same count and same type. \
        If word order requires reordering arguments, switch ALL specifiers in that string to \
        positional form (%1$@, %2$lld). "%%" is a literal percent sign; keep it.
        - Keep untranslated: Chorus, macOS, iCloud Drive, DDC, DDC/CI, VCP, HDMI, DisplayPort, USB-C, \
        AutoEq, Audio Unit, Bearer token, CLI, engine names, file paths, hex codes, URLs, and anything \
        that looks like an identifier or a command.
        - Preserve leading markers such as ▲ and ⓘ, and preserve line breaks.
        - Never leave anything in English or Chinese unless the rule above says to keep it.

        Input:
        \(inputJSON(items))

        \(AdvicePrompt.outputInstruction)
        \(schemaJSON)
        """
    }

    /// 輸入 JSON：順序固定、不逃逸非 ASCII（模型看原文比看 \\u 序列準）。
    static func inputJSON(_ items: [UITranslationItem]) -> String {
        var lines: [String] = ["["]
        for (index, item) in items.enumerated() {
            var fields = ["\"id\": \(item.id)", "\"zh_Hant\": \(quote(item.key))"]
            if let english = item.english { fields.append("\"en\": \(quote(english))") }
            if let plural = item.plural {
                let forms = plural.keys.sorted().map { "\(quote($0)): \(quote(plural[$0]!))" }
                fields.append("\"plural_en\": {\(forms.joined(separator: ", "))}")
            }
            lines.append("  {\(fields.joined(separator: ", "))}\(index == items.count - 1 ? "" : ",")")
        }
        lines.append("]")
        return lines.joined(separator: "\n")
    }

    private static func quote(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// 翻譯結果的最低防線：format specifier 數量與型別要跟來源一致，否則執行期
/// `String(format:)` 會讀錯參數甚至崩潰；不合格的直接丟掉、退回內建英文。
public enum UITranslationValidator {
    /// `%@`、`%lld`、`%1$@`… 去掉位置編號後排序，供多重集合比對。
    /// 不接受空白旗標（"100% passes" 不是 specifier），`%%` 不算。
    public static func normalizedSpecifiers(_ text: String) -> [String] {
        var result: [String] = []
        let scalars = Array(text.unicodeScalars)
        var i = 0
        while i < scalars.count {
            guard scalars[i] == "%" else { i += 1; continue }
            var j = i + 1
            if j < scalars.count, scalars[j] == "%" { i = j + 1; continue }
            // 位置編號 n$
            var k = j
            while k < scalars.count, ("0"..."9").contains(scalars[k]) { k += 1 }
            if k < scalars.count, scalars[k] == "$", k > j { j = k + 1 }
            // 旗標與寬度／精度
            while j < scalars.count, "-+0#".unicodeScalars.contains(scalars[j]) { j += 1 }
            while j < scalars.count, ("0"..."9").contains(scalars[j]) || scalars[j] == "." { j += 1 }
            // 長度修飾
            for modifier in ["ll", "hh", "l", "h", "q", "z", "t", "j"] {
                let m = Array(modifier.unicodeScalars)
                if j + m.count <= scalars.count, Array(scalars[j..<(j + m.count)]) == m {
                    j += m.count
                    break
                }
            }
            guard j < scalars.count, "@diufsxXeEgGcaAp".unicodeScalars.contains(scalars[j]) else {
                i += 1
                continue
            }
            var spec = "%"
            spec.unicodeScalars.append(contentsOf: scalars[(i + 1)...j])
            // 去掉位置編號：%1$@ → %@
            if let dollar = spec.firstIndex(of: "$") {
                spec = "%" + spec[spec.index(after: dollar)...]
            }
            result.append(spec)
            i = j + 1
        }
        return result.sorted()
    }

    /// 單一字串是否可接受：非空、specifier 一致、沒有把原文原封不動吐回來
    /// （原文本身沒有中日韓文字的除外，例如 "DDC/CI"）。
    public static func isAcceptable(candidate: String, source: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard normalizedSpecifiers(candidate) == normalizedSpecifiers(source) else { return false }
        return true
    }
}
