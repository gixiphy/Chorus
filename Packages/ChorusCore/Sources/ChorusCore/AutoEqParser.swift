import Foundation

/// AutoEq 的 `ParametricEQ.txt` 解析（B6-5）。
///
/// 資料與程式碼來源：**AutoEq**（https://github.com/jaakkopasanen/AutoEq，
/// MIT）。授權允許使用，需標註來源（PLAN §8-1）——設定頁的 EQ 面板也會
/// 把來源顯示給使用者看。
///
/// 檔案長這樣：
///
///     Preamp: -6.8 dB
///     Filter 1: ON PK Fc 105 Hz Gain -2.4 dB Q 0.70
///     Filter 2: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
///     Filter 3: OFF PK Fc 1000 Hz Gain 0.0 dB Q 1.00
///
/// 純函式、沒有 I/O——下載與快取是呼叫端的事，這裡只認字串。
public enum AutoEqParser: Sendable {
    /// 濾波器型別代號。AutoEq 寫 `PK`／`LSC`／`HSC`，別的工具匯出的
    /// 同格式檔案有時寫 `LS`／`HS`，一併收。
    private static func kind(for token: String) -> BiquadKind? {
        switch token.uppercased() {
        case "PK", "PEQ": .peaking
        case "LSC", "LS", "LSQ": .lowShelf
        case "HSC", "HS", "HSQ": .highShelf
        default: nil
        }
    }

    /// 解析成一組 EQ 設定。至少要有一段有效的 filter 才算成功——
    /// 只有 `Preamp:` 一行的檔案是壞的，不該安靜地變成「EQ 全平」。
    public static func parse(_ text: String, sourceName: String? = nil) -> EQSettings? {
        var preampDB: Double?
        var bands: [EQBand] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.lowercased().hasPrefix("preamp:") {
                preampDB = firstNumber(in: line.dropFirst("preamp:".count))
                continue
            }
            guard line.lowercased().hasPrefix("filter") else { continue }
            guard let band = parseFilter(line) else { continue }
            bands.append(band)
        }

        guard !bands.isEmpty else { return nil }
        return EQSettings(
            isEnabled: true,
            // 檔案給了就用檔案的（AutoEq 算過整條曲線的峰值，比我們逐段
            // 取最大值準）；沒給才退回自動計算
            preampDB: preampDB ?? 0,
            usesAutomaticPreamp: preampDB == nil,
            bands: bands,
            sourceName: sourceName
        )
    }

    /// `Filter 1: ON PK Fc 105 Hz Gain -2.4 dB Q 0.70`
    ///
    /// 以關鍵字定位而不是數欄位：不同工具在 `Fc`／`Gain`／`Q` 之間的
    /// 空白與單位寫法不一致，數欄位會在第一個變體上就散掉。
    private static func parseFilter(_ line: String) -> EQBand? {
        let tokens = line.split(separator: " ").map(String.init)
        guard let stateIndex = tokens.firstIndex(where: { $0 == "ON" || $0 == "OFF" }),
              stateIndex + 1 < tokens.count,
              let kind = kind(for: tokens[stateIndex + 1])
        else { return nil }

        guard let frequency = value(after: "Fc", in: tokens), frequency > 0 else { return nil }
        let gain = value(after: "Gain", in: tokens) ?? 0
        // Q 缺席時用 AutoEq 的常見預設；沒有它算不出係數
        let q = value(after: "Q", in: tokens) ?? 0.707

        return EQBand(
            kind: kind,
            frequency: frequency,
            gainDB: gain,
            q: q,
            isEnabled: tokens[stateIndex] == "ON"
        )
    }

    /// 關鍵字後面第一個解析得出來的數字（跳過 `Hz`／`dB` 這類單位）。
    private static func value(after keyword: String, in tokens: [String]) -> Double? {
        guard let index = tokens.firstIndex(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame })
        else { return nil }
        for token in tokens[(index + 1)...] {
            if let number = Double(token) { return number }
        }
        return nil
    }

    private static func firstNumber(in text: some StringProtocol) -> Double? {
        for token in text.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            if let number = Double(token) { return number }
        }
        return nil
    }
}
