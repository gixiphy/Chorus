import Foundation

/// CLI 輸出 → `LightingAdvice` 的解析方式（DESIGN-ai-provider-layer §0.1）。
/// 三種 codec 收斂到同一條尾巴：取出回應文字 → 剝 code fence → decode。
/// 解析結果未經 sanitized —— 呼叫端一律再過 `sanitized(for:)` 才可用。
public enum AdviceOutputCodec: String, Codable, Sendable {
    /// claude `--output-format json`：單一 JSON envelope，取 `result` 欄位。
    case jsonEnvelope
    /// agy（Antigravity）`--output-format json`：envelope 欄位是 `response`／`status`，
    /// 且搭配 `--json-schema` 時另有一個已解析好的 `structured_output` 物件。
    /// **優先吃 structured_output**——那是 CLI 依 schema 驗過的結果，
    /// 比從 `response` 文字剝 fence 再 decode 少一層可能出錯的環節。
    case responseEnvelope
    /// grok（Grok Build）`--output-format json`：envelope 欄位是 `text`。
    case textEnvelope
    /// 通用退路：整段 stdout 就是回應文字。
    /// codex／opencode 都適用——它們把前言與進度寫 stderr，stdout 只有最終回覆。
    case plainStdout
}

/// 解析失敗的型別化錯誤；`raw` 帶原始文字供 UI 顯示與回報。
public enum AdviceDecodeError: Error, Equatable, Sendable {
    case emptyOutput
    /// envelope 本身不是合法 JSON、或缺 `result` 欄位。
    case envelopeParseFailed(raw: String)
    /// CLI 在 envelope 中回報執行錯誤（`is_error: true`）。
    case cliReportedError(message: String)
    /// 回應文字無法 decode 成 `LightingAdvice`。
    case adviceParseFailed(raw: String)
}

public enum AdviceCodec {
    /// 依 codec 從 CLI stdout 解出 `LightingAdvice`（未 sanitized）。
    /// 既有呼叫端的相容包裝——泛型版在下面。
    public static func decode(stdout: String, codec: AdviceOutputCodec) throws -> LightingAdvice {
        try decode(stdout: stdout, codec: codec, as: LightingAdvice.self)
    }

    /// 泛型版：同一條「取回應文字 → 剝 fence → decode → 撈嵌入 JSON」尾巴，
    /// 光環境與音訊調音兩個顧問共用（機制只寫一份）。
    public static func decode<T: Decodable>(
        stdout: String, codec: AdviceOutputCodec, as type: T.Type
    ) throws -> T {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AdviceDecodeError.emptyOutput }

        let responseText: String
        switch codec {
        case .jsonEnvelope:
            responseText = try envelopeResult(from: trimmed)
        case .responseEnvelope:
            if let advice: T = try structuredOutput(from: trimmed) { return advice }
            responseText = try responseField(from: trimmed)
        case .textEnvelope:
            responseText = try stringField("text", from: trimmed)
        case .plainStdout:
            responseText = trimmed
        }

        let body = strippingCodeFence(responseText)
        if let advice: T = decodeAdvice(body) { return advice }
        // 模型常在 JSON 前面加一段旁白（實測 grok 會先講「我要先讀取照片…」
        // 再接 JSON）。整段 decode 必然失敗，但那段 JSON 本身是好的——
        // 撈出第一個成對的大括號區塊再試一次，比叫模型重來便宜得多。
        if let embedded = firstJSONObject(in: body), let advice: T = decodeAdvice(embedded) {
            return advice
        }
        throw AdviceDecodeError.adviceParseFailed(raw: responseText)
    }

    private static func decodeAdvice<T: Decodable>(_ text: String) -> T? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// 取出文字中第一個成對的 `{…}` 區塊。以括號深度掃描，
    /// 並略過字串字面值裡的括號與逃逸字元（`"a{b"` 不該影響深度）。
    public static func firstJSONObject(in text: String) -> String? {
        var depth = 0
        var start: String.Index?
        var inString = false
        var escaped = false
        for index in text.indices {
            let character = text[index]
            if escaped { escaped = false; continue }
            if inString {
                if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"":
                inString = true
            case "{":
                if depth == 0 { start = index }
                depth += 1
            case "}":
                guard depth > 0 else { break }
                depth -= 1
                if depth == 0, let start {
                    return String(text[start...index])
                }
            default:
                break
            }
        }
        return nil
    }

    /// 剝除包住整段回應的 markdown code fence（```json … ```）；沒有 fence 原樣返回。
    public static func strippingCodeFence(_ text: String) -> String {
        var lines = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
        guard let first = lines.first, first.hasPrefix("```") else { return text }
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// agy envelope 的 `structured_output`：CLI 已依 `--json-schema` 驗過的物件。
    /// 沒有這個欄位（未帶 schema 或舊版 CLI）回 nil，交給 `response` 文字路徑。
    private static func structuredOutput<T: Decodable>(from text: String) throws -> T? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let structured = object["structured_output"]
        else { return nil }
        guard let encoded = try? JSONSerialization.data(withJSONObject: structured),
              let advice = try? JSONDecoder().decode(T.self, from: encoded)
        else {
            throw AdviceDecodeError.adviceParseFailed(raw: text)
        }
        return advice
    }

    /// 取 envelope 的某個字串欄位；缺欄位或內容為空都視為失敗
    /// （空回應的真正原因通常在 stderr，由呼叫端補上）。
    private static func stringField(_ key: String, from text: String) throws -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AdviceDecodeError.envelopeParseFailed(raw: text) }
        guard let value = object[key] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw AdviceDecodeError.emptyOutput }
        return value
    }

    /// agy envelope 的 `response` 欄位。
    ///
    /// **不看 `status`**：實測（agy 1.1.19）headless 權限被拒時 `status` 仍是
    /// `SUCCESS`、`response` 是空字串，真正的原因只出現在 stderr。
    /// 因此這裡以「response 為空」為失敗判準，由呼叫端補上 stderr 說明。
    private static func responseField(from text: String) throws -> String {
        try stringField("response", from: text)
    }

    private static func envelopeResult(from text: String) throws -> String {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AdviceDecodeError.envelopeParseFailed(raw: text) }
        let result = object["result"] as? String
        if let isError = object["is_error"] as? Bool, isError {
            throw AdviceDecodeError.cliReportedError(message: result ?? text)
        }
        guard let result else { throw AdviceDecodeError.envelopeParseFailed(raw: text) }
        return result
    }
}
