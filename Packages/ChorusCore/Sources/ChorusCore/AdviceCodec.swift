import Foundation

/// CLI 輸出 → `LightingAdvice` 的解析方式（DESIGN-ai-provider-layer §0.1）。
/// 三種 codec 收斂到同一條尾巴：取出回應文字 → 剝 code fence → decode。
/// 解析結果未經 sanitized —— 呼叫端一律再過 `sanitized(for:)` 才可用。
public enum AdviceOutputCodec: String, Codable, Sendable {
    /// claude `--output-format json`：單一 JSON envelope，取 `result` 欄位。
    case jsonEnvelope
    /// 通用退路：整段 stdout 就是回應文字。
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
    public static func decode(stdout: String, codec: AdviceOutputCodec) throws -> LightingAdvice {
        let trimmed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw AdviceDecodeError.emptyOutput }

        let responseText: String
        switch codec {
        case .jsonEnvelope:
            responseText = try envelopeResult(from: trimmed)
        case .plainStdout:
            responseText = trimmed
        }

        let body = strippingCodeFence(responseText)
        guard let data = body.data(using: .utf8),
              let advice = try? JSONDecoder().decode(LightingAdvice.self, from: data)
        else { throw AdviceDecodeError.adviceParseFailed(raw: responseText) }
        return advice
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
