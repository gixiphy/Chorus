import Foundation

/// 解析後的值。
public enum ControlValue: Sendable, Equatable, Hashable {
    /// 絕對值（unitInterval 已夾在 0–1；signedUnit 夾在 -0.5…+0.5）。
    case absolute(Double)
    /// 相對增減，疊加在現值上後由 executor 夾範圍。
    case offset(Double)
    case boolean(Bool)
    /// 依 `KeepAwakePlanner` 的編碼：0 = 關、負值 = 無限期、正值 = 秒數。
    case duration(Double)
    case rawCode(UInt16)
}

public extension ControlValue {
    /// 收值規則（三種寫法都收，學 BetterDisplay）：
    ///
    /// - `0.8` → 0.8（0–1 直接視為比例）
    /// - `80%` → 0.8
    /// - `80`  → 0.8（**> 1 的裸數字一律視為百分比**）
    /// - `+10%` / `-0.1` → offset
    ///
    /// `80` 的歧義是刻意解成百分比的：人與 LLM 打 `--brightness 80` 的意圖
    /// 幾乎必然是 80%。兩種讀法只在 `1` 這點重疊，而 `1` 解成 100% 同值、無歧義。
    static func parse(_ text: String, kind: ControlValueKind) throws(ControlError) -> ControlValue {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw ControlError.badValue(text, hint: "值不可為空")
        }
        return switch kind {
        case .boolean: try parseBoolean(trimmed, original: text)
        case .rawCode: try parseRawCode(trimmed, original: text)
        case .duration: try parseDuration(trimmed, original: text)
        case .unitInterval:
            try parseScalar(trimmed, original: text, range: 0...1, allowsRelative: true)
        case .signedUnit:
            // 差異值本身就有正負號，前導 +/- 是**絕對值的一部分**，不是相對增減。
            // 否則 `ambientOffset -0.2`（合法的絕對值）會被讀成「再減 0.2」。
            try parseScalar(trimmed, original: text, range: -0.5...0.5, allowsRelative: false)
        }
    }

    private static func parseBoolean(_ text: String, original: String) throws(ControlError) -> ControlValue {
        switch text.lowercased() {
        case "on", "true", "1", "yes", "開": .boolean(true)
        case "off", "false", "0", "no", "關": .boolean(false)
        default: throw ControlError.badValue(original, hint: "布林值請用 on/off、true/false、1/0")
        }
    }

    private static func parseRawCode(_ text: String, original: String) throws(ControlError) -> ControlValue {
        // 十六進位也收：MCCS 輸入源代碼在文件與螢幕 OSD 上常寫成 0x0F
        let value: UInt16? = text.lowercased().hasPrefix("0x")
            ? UInt16(text.dropFirst(2), radix: 16)
            : UInt16(text)
        guard let value else {
            throw ControlError.badValue(original, hint: "請給整數 MCCS 代碼（可用十進位或 0x 十六進位）")
        }
        return .rawCode(value)
    }

    private static func parseDuration(_ text: String, original: String) throws(ControlError) -> ControlValue {
        let lower = text.lowercased()
        switch lower {
        case "off", "0", "關": return .duration(0)
        case "forever", "indefinite", "∞", "無限期": return .duration(-1)
        default: break
        }
        let multipliers: [(suffix: String, seconds: Double)] = [
            ("h", 3600), ("m", 60), ("s", 1),
        ]
        for (suffix, seconds) in multipliers where lower.hasSuffix(suffix) {
            if let amount = Double(lower.dropLast(suffix.count)), amount > 0 {
                return .duration(amount * seconds)
            }
        }
        // 裸數字視為秒
        if let amount = Double(lower), amount > 0 {
            return .duration(amount)
        }
        throw ControlError.badValue(original, hint: "時長請用 off、30m、1h、90s 或 forever")
    }

    private static func parseScalar(
        _ text: String,
        original: String,
        range: ClosedRange<Double>,
        allowsRelative: Bool
    ) throws(ControlError) -> ControlValue {
        let isRelative = allowsRelative && (text.hasPrefix("+") || text.hasPrefix("-"))
        let isPercent = text.hasSuffix("%")
        var body = text
        if isPercent { body.removeLast() }
        // Double("+10") 本來就吃得下正號，這裡不用另外剝
        guard let raw = Double(body.trimmingCharacters(in: .whitespaces)) else {
            throw ControlError.badValue(
                original,
                hint: "請給 0–1 的比例、百分比（80%）或相對增減（+10%）"
            )
        }
        // 百分比一律除以 100；裸數字則以「> 1 即百分比」判斷
        // （相對值同理：+10 是 +10%，+0.1 是 +0.1）
        let scaled = isPercent || abs(raw) > 1 ? raw / 100 : raw
        if isRelative {
            return .offset(scaled)
        }
        return .absolute(min(max(scaled, range.lowerBound), range.upperBound))
    }
}
