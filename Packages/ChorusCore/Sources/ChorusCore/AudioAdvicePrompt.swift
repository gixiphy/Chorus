import Foundation

/// 音訊調音顧問的 prompt 與 schema（DESIGN-20260831-audio-tuning-advisor）。
/// 與 AdvicePrompt 同一套紀律：純字串組裝、輸出順序固定、可快照測試。
/// 純文字任務——沒有照片、不需要 vision。prompt 是英文，回覆語言是參數。
public enum AudioAdvicePrompt {
    public static func systemPrompt(responseLanguage: String = AdviceLanguage.current) -> String {
        """
        You are the audio tuning advisor for Chorus, a macOS audio control app. The user names a \
        tuning target (one app's audio, or an output device's overall audio) and provides a request \
        description, the adjustable 10-band equalizer frequencies, and the list of Audio Unit effects \
        actually available on this Mac.

        What to look for:
        - Infer the content type from the target: music apps, video, games, conferencing and podcasts \
        each have their own spectral priorities and problems (vocal clarity, footstep localization, \
        low-end boom, sibilance).
        - The user's request comes first; without one, give a generic starting point for that kind \
        of content.
        - For device targets, consider the transducer (headphones, speakers, a monitor's built-in \
        speakers): small speakers cannot reproduce sub-bass, and boosting 31.5 Hz only wastes headroom.

        Output discipline (write all text in \(responseLanguage)):
        - Start EQ gains conservatively: |gain| ≤ 6 dB; move fewer bands rather than drawing a wave. \
        If every band would be 0, omit the eq field.
        - Effects may only be picked from the input Audio Unit list (componentKey verbatim), at most \
        3, each with one concrete reason; if nothing fits, return an empty array rather than forcing \
        a pick.
        - Put uncertain observations in warnings (for example "if sibilance persists, cut 8 kHz by \
        another 1–2 dB"); do not invent numbers or effects.
        - summary explains the overall approach in 2–3 sentences.
        """
    }

    /// 輸出 JSON Schema，形狀與 `AudioTuningAdvice` 的 Codable 對稱。
    /// 數值範圍與 `sanitized(for:)` 一致（schema 擋第一線，本地保底）。
    public static func schemaJSON(responseLanguage: String = AdviceLanguage.current) -> String {
        """
        {
          "type": "object",
          "properties": {
            "summary": { "type": "string", "description": "Overall approach (\(responseLanguage), 2–3 sentences)" },
            "eq": {
              "type": "object",
              "properties": {
                "bandsGainDB": {
                  "type": "array",
                  "items": { "type": "number", "minimum": -12, "maximum": 12 },
                  "description": "10 gains (dB) in the order of the input frequencies; keep |gain| ≤ 6"
                },
                "reason": { "type": "string", "description": "One-sentence reason in \(responseLanguage)" }
              },
              "required": ["bandsGainDB", "reason"]
            },
            "effects": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "componentKey": { "type": "string", "description": "Must come from the input Audio Unit list" },
                  "name": { "type": "string" },
                  "reason": { "type": "string", "description": "One-sentence reason in \(responseLanguage)" }
                },
                "required": ["componentKey", "name", "reason"]
              }
            },
            "warnings": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Reminders that do not apply any action (\(responseLanguage))"
            }
          },
          "required": ["summary", "effects", "warnings"]
        }
        """
    }

    /// context → user message 文字。順序固定，可快照測試。
    /// 使用者的需求描述原樣夾帶，不翻譯。
    public static func contextDescription(_ context: AudioTuningContext) -> String {
        var lines: [String] = []
        let kind = context.targetKind == "app" ? "App" : "output device"
        lines.append("Tuning target (\(kind)): \"\(context.targetName)\" \(context.targetDetail)")
        let request = context.request.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(request.isEmpty
            ? "User request: none (give a generic starting point)"
            : "User request: \(request)")
        lines.append(
            "Equalizer bands (Hz; bandsGainDB follows this order): "
                + context.bandFrequencies.map { String(format: "%.4g", locale: nil, $0) }
                    .joined(separator: ", ")
        )
        if context.availableEffects.isEmpty {
            lines.append("Available Audio Unit effects: (none — return an empty array for effects)")
        } else {
            lines.append("Available Audio Unit effects (componentKey — name — manufacturer):")
            for option in context.availableEffects {
                lines.append("- \(option.key) — \(option.name) — \(option.manufacturerName)")
            }
        }
        if !context.currentEQDescription.isEmpty {
            lines.append("Current EQ: \(context.currentEQDescription)")
        }
        if !context.currentEffectsDescription.isEmpty {
            lines.append("Current effect chain: \(context.currentEffectsDescription)")
        }
        return lines.joined(separator: "\n")
    }

    /// CLI 單發呼叫的完整 prompt。與 AdvicePrompt.cliPrompt 同構，
    /// 少了照片段落。
    public static func cliPrompt(
        context: AudioTuningContext,
        responseLanguage: String = AdviceLanguage.current
    ) -> String {
        """
        \(systemPrompt(responseLanguage: responseLanguage))

        \(contextDescription(context))

        \(AdvicePrompt.outputInstruction)
        \(schemaJSON(responseLanguage: responseLanguage))
        """
    }
}
