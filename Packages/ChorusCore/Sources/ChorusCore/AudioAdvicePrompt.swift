import Foundation

/// 音訊調音顧問的 prompt 與 schema（DESIGN-20260831-audio-tuning-advisor）。
/// 與 AdvicePrompt 同一套紀律：純字串組裝、輸出順序固定、可快照測試。
/// 純文字任務——沒有照片、不需要 vision。
public enum AudioAdvicePrompt {
    public static let systemPrompt = """
    你是 Chorus（macOS 音訊控制 App）的音訊調音顧問。使用者會指定一個調音目標\
    （某個 App 的音訊，或某個輸出裝置的整體音訊），並附上需求描述、可調的 10 段\
    等化器頻率、以及這台機器上實際可用的 Audio Unit 效果清單。

    判讀重點：
    - 依目標的性質推斷內容型態：音樂 App、影片、遊戲、通訊會議、Podcast 各有\
    不同的頻譜重點與問題（人聲清晰度、腳步聲定位、低頻轟鳴、齒音）。
    - 使用者的需求描述是第一優先；沒有描述時給該類內容的通用起步建議。
    - 裝置目標要考慮換能器類型（耳機／喇叭／螢幕內建喇叭）：小喇叭補不了\
    超低頻，推 31.5 Hz 只會浪費 headroom。

    輸出紀律（所有文字使用繁體中文）：
    - EQ 增益保守起步：|gain| ≤ 6 dB；寧可少動幾段，不要畫一條波浪。\
    全部為 0 就不要給 eq 欄位。
    - 效果只能從輸入的 Audio Unit 清單挑（componentKey 一字不差），最多 3 個，\
    每個都要有一句具體理由；清單裡沒有合適的就給空陣列，不要硬湊。
    - 不確定的觀察寫進 warnings（例如「若齒音仍明顯，把 8 kHz 再降 1–2 dB」），\
    不要編造數值或效果。
    - summary 用 2–3 句說明整體思路。
    """

    /// 輸出 JSON Schema，形狀與 `AudioTuningAdvice` 的 Codable 對稱。
    /// 數值範圍與 `sanitized(for:)` 一致（schema 擋第一線，本地保底）。
    public static let schemaJSON = """
    {
      "type": "object",
      "properties": {
        "summary": { "type": "string", "description": "整體思路（繁體中文，2–3 句）" },
        "eq": {
          "type": "object",
          "properties": {
            "bandsGainDB": {
              "type": "array",
              "items": { "type": "number", "minimum": -12, "maximum": 12 },
              "description": "依輸入頻率順序的 10 個增益（dB），保守 |gain| ≤ 6"
            },
            "reason": { "type": "string", "description": "繁體中文一句話理由" }
          },
          "required": ["bandsGainDB", "reason"]
        },
        "effects": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "componentKey": { "type": "string", "description": "必須來自輸入的 Audio Unit 清單" },
              "name": { "type": "string" },
              "reason": { "type": "string", "description": "繁體中文一句話理由" }
            },
            "required": ["componentKey", "name", "reason"]
          }
        },
        "warnings": {
          "type": "array",
          "items": { "type": "string" },
          "description": "無套用動作的提醒（繁體中文）"
        }
      },
      "required": ["summary", "effects", "warnings"]
    }
    """

    /// context → user message 文字。順序固定，可快照測試。
    public static func contextDescription(_ context: AudioTuningContext) -> String {
        var lines: [String] = []
        let kind = context.targetKind == "app" ? "App" : "輸出裝置"
        lines.append("調音目標（\(kind)）：「\(context.targetName)」 \(context.targetDetail)")
        let request = context.request.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(request.isEmpty ? "使用者需求：未描述（請給通用起步建議）" : "使用者需求：\(request)")
        lines.append(
            "等化器頻段（Hz，bandsGainDB 依此順序）："
                + context.bandFrequencies.map { String(format: "%.4g", locale: nil, $0) }
                    .joined(separator: ", ")
        )
        if context.availableEffects.isEmpty {
            lines.append("可用的 Audio Unit 效果：（無——effects 請給空陣列）")
        } else {
            lines.append("可用的 Audio Unit 效果（componentKey — 名稱 — 廠商）：")
            for option in context.availableEffects {
                lines.append("- \(option.key) — \(option.name) — \(option.manufacturerName)")
            }
        }
        if !context.currentEQDescription.isEmpty {
            lines.append("現行 EQ：\(context.currentEQDescription)")
        }
        if !context.currentEffectsDescription.isEmpty {
            lines.append("現行效果鏈：\(context.currentEffectsDescription)")
        }
        return lines.joined(separator: "\n")
    }

    /// CLI 單發呼叫的完整 prompt。與 AdvicePrompt.cliPrompt 同構，
    /// 少了照片段落。
    public static func cliPrompt(context: AudioTuningContext) -> String {
        """
        \(systemPrompt)

        \(contextDescription(context))

        只輸出一個 JSON 物件（不要 markdown fence、不要其他文字），必須符合以下 JSON Schema：
        \(schemaJSON)
        """
    }
}
