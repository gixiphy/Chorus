import Foundation
import os

/// 一張送進分析的照片與它的照明情境標註。
/// 標註是使用者手寫的（例：「夜晚，只開掛燈」）；空字串表示未標註。
/// 照片是自動曝光的，單看畫面判斷不出絕對亮度，也分不出「暗處沒有燈」與
/// 「暗處的燈關著」——標註補的就是這段畫面拍不出來的資訊。
public struct LabeledPhoto: Sendable, Equatable {
    public var path: String
    public var label: String

    public init(path: String, label: String = "") {
        self.path = path
        self.label = label
    }
}

/// 顧問回覆要用的語言。**跟著 App 目前的介面語言走**：介面切到英文，
/// 模型就用英文寫 summary／reason／warnings；prompt 本體一律是英文。
public enum AdviceLanguage {
    private static let overrideBox = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// App 端安裝的使用者自翻介面語言（DESIGN-20260902-user-cli-translation）。
    /// 那條路不經 `Bundle.main.preferredLocalizations`，所以要在這裡另外告知；
    /// nil＝沒有覆蓋，跟內建語言走。啟動時設一次。
    public static var localizationOverride: String? {
        get { overrideBox.withLock { $0 } }
        set { overrideBox.withLock { $0 = newValue } }
    }

    /// 目前介面語言的英文名稱（例：「Chinese (Traditional)」、「English」）。
    /// `Bundle.main.preferredLocalizations` 已經是「使用者偏好 ∩ App 有的語言」，
    /// 所以系統是日文但 App 只有中英時，這裡會落到 App 實際顯示的那個。
    public static var current: String {
        name(forLocalization: localizationOverride ?? Bundle.main.preferredLocalizations.first ?? "en")
    }

    /// 語言代碼 → 英文語言名，給 prompt 用（模型看英文名最不會誤解）。
    public static func name(forLocalization identifier: String) -> String {
        Locale(identifier: "en_US").localizedString(forIdentifier: identifier) ?? identifier
    }
}

/// 光環境顧問的 prompt 與結構化輸出工具 schema。
/// 純字串組裝，輸出順序固定，可快照測試；API 呼叫本體在 app 層。
/// prompt 是英文，只有「回覆語言」是參數——使用者輸入的標註與需求原樣夾帶。
public enum AdvicePrompt {
    /// 強制呼叫的結構化輸出工具名（`tool_choice: {type: "tool"}`）。
    public static let toolName = "submit_lighting_advice"

    /// 系統提示。判讀重點與輸出紀律見設計文件 §3。
    public static func systemPrompt(responseLanguage: String = AdviceLanguage.current) -> String {
        """
        You are the display dimming advisor for Chorus, a macOS app that syncs brightness and volume \
        across Macs. The user provides a photo of their desk setup plus a list of displays (each with \
        its node's normalized 0–1 coordinates on the photo, its brightness backend and its current \
        offset) and the current auto-brightness curve parameters.

        What to look for:
        - Light sources, their type and direction: windows, ceiling lights, desk lamps, monitor light \
        bars, and where each sits relative to each display.
        - Background luminance behind each display: a display against a bright background needs a \
        positive offset so it does not look dim.
        - Shadow bands and glare risk: shelves casting shade, a light bar or lamp shining directly \
        onto a panel.
        - Where the ambient light sensor is: a MacBook's ALS sits near the notch at the top edge of \
        its screen. Judge which light sources hit it and whether its reading runs high or low \
        relative to the desk as a whole.
        - Multiple photos may capture different lighting scenarios (labels state daytime, nighttime \
        or which lights are on). Compare them to separate permanent factors (shelf shade, display \
        orientation) from lights that merely happen to be on. Photos are auto-exposed, so image \
        brightness is not absolute illuminance; trust the labels and the lux statistics instead.

        Output discipline (always report through the \(toolName) tool; write all text in \(responseLanguage)):
        - offset is an absolute recommendation, not a delta. Start conservatively (|offset| ≤ 0.15); \
        the learning mechanism fine-tunes from the user's manual corrections, so it need not be \
        perfect on the first pass.
        - offset is the relative difference between displays and must hold in every lighting \
        scenario. Tracking the environment's overall brightness is the job of the maxLux/minBrightness \
        curve; do not use offset to compensate for one scenario being light or dark.
        - Displays whose backend is "gamma" can only be dimmed in software, never brightened: warn \
        the user to first set the hardware backlight via the monitor's OSD to a level that is \
        comfortable in the brightest scenario.
        - Provide maxLux/minBrightness only when the photos and lux statistics clearly support them; \
        put uncertain observations in warnings instead of inventing numbers.
        - displayID must come from the input list; at most one offset suggestion per display.
        """
    }

    /// 工具 input_schema（JSON Schema），形狀與 `LightingAdvice` 的 Codable 對稱。
    /// 數值範圍與 `LightingAdvice` 的夾值範圍一致（schema 擋第一線，sanitized 保底）。
    public static func toolInputSchemaJSON(responseLanguage: String = AdviceLanguage.current) -> String {
        """
        {
          "type": "object",
          "properties": {
            "sceneSummary": {
              "type": "string",
              "description": "Overall description of the lighting environment in the photos (\(responseLanguage), 2–4 sentences)"
            },
            "offsets": {
              "type": "array",
              "items": {
                "type": "object",
                "properties": {
                  "displayID": { "type": "string", "description": "Must come from the input display list" },
                  "offset": { "type": "number", "minimum": -0.3, "maximum": 0.3 },
                  "reason": { "type": "string", "description": "One-sentence reason in \(responseLanguage)" }
                },
                "required": ["displayID", "offset", "reason"]
              }
            },
            "maxLux": { "type": "number", "minimum": 100, "maximum": 20000 },
            "minBrightness": { "type": "number", "minimum": 0, "maximum": 0.5 },
            "warnings": {
              "type": "array",
              "items": { "type": "string" },
              "description": "Reminders that do not apply any action (\(responseLanguage))"
            }
          },
          "required": ["sceneSummary", "offsets", "warnings"]
        }
        """
    }

    /// context → user message 的文字描述（照片以外的部分）。
    /// 顯示器依輸入順序列出，數字格式固定。
    public static func contextDescription(_ context: AdviceContext) -> String {
        var lines: [String] = ["Displays:"]
        for display in context.displays {
            var parts = [
                "- id=\(display.id)",
                "name=\"\(display.name)\"",
                "backend=\(display.backend)"
            ]
            if let position = display.normalizedPosition, position.count == 2 {
                parts.append("photoPosition=(\(format(position[0], decimals: 2)), \(format(position[1], decimals: 2)))")
            } else {
                parts.append("photoPosition=not placed")
            }
            parts.append("currentOffset=\(formatSigned(display.currentOffset))")
            lines.append(parts.joined(separator: " "))
        }
        lines.append(
            "Current curve: minBrightness=\(format(context.curve.minBrightness, decimals: 2)) "
                + "maxLux=\(format(context.curve.maxLux, decimals: 0))"
        )
        if let lux = context.recentLux {
            lines.append(
                "Recent ambient light (lux): min=\(format(lux.minLux, decimals: 0)) "
                    + "median=\(format(lux.medianLux, decimals: 0)) "
                    + "max=\(format(lux.maxLux, decimals: 0))"
            )
        } else {
            lines.append("Recent ambient light: no data (this Mac has no ambient light sensor)")
        }
        if let hasLightBar = context.hasLightBarHint {
            lines.append(hasLightBar
                ? "User note: the desk has a monitor light bar"
                : "User note: the desk has no monitor light bar")
        }
        return lines.joined(separator: "\n")
    }

    /// CLI 單發呼叫的完整 prompt：系統提示＋context＋照片路徑＋輸出格式指示。
    /// API forced tool_use 在 CLI 情境改為「指示＋本地驗證」——schema 常數同源，
    /// `sanitized(for:)` 仍是最後防線。`readInstruction` 由引擎決定
    /// （claude 有 Read 工具，其他 CLI 用通用措辭）。
    /// 多張照片：第一張是配置圖背景照（節點座標以它為準），其餘是補充視角。
    /// 有標註的照片會把照明情境接在路徑後面；未標註的維持只有路徑。
    public static func cliPrompt(
        context: AdviceContext,
        photos: [LabeledPhoto],
        readInstruction: String,
        delivery: PhotoDelivery = .pathInPrompt,
        responseLanguage: String = AdviceLanguage.current
    ) -> String {
        let photoLines = photoSection(photos: photos, readInstruction: readInstruction, delivery: delivery)
        return """
        \(systemPrompt(responseLanguage: responseLanguage))

        \(contextDescription(context))

        \(photoLines)

        \(outputInstruction)
        \(toolInputSchemaJSON(responseLanguage: responseLanguage))
        """
    }

    /// 兩位顧問共用的收尾句：只要 JSON，不要 fence。
    public static let outputInstruction =
        "Output exactly one JSON object (no markdown fence, no other text) that conforms to this JSON Schema:"

    /// 照片怎麼送到模型手上。決定 prompt 要不要講路徑與「請先讀取」。
    public enum PhotoDelivery: Sendable, Equatable {
        /// 路徑寫進 prompt，由模型自己用讀檔工具取（claude／agy／grok）。
        case pathInPrompt
        /// CLI 以參數直接附加影像（codex `--image`、opencode `-f`、pi `@path`）——
        /// 模型已經看得到圖，再叫它「去讀某個路徑」只會誘發多餘的工具呼叫。
        case attached
    }

    private static func photoSection(
        photos: [LabeledPhoto],
        readInstruction: String,
        delivery: PhotoDelivery
    ) -> String {
        guard !photos.isEmpty else { return "Desk photo: (none)" }
        let ordering = "photo 1 is the layout background and display coordinates refer to it; "
            + "the rest are supplementary views"
        switch delivery {
        case .attached:
            if photos.count == 1 {
                return "The desk photo is attached to this message\(labelSuffix(photos[0].label))."
            }
            var lines = ["\(photos.count) desk photos are attached to this message in order (\(ordering)):"]
            for (index, photo) in photos.enumerated() {
                lines.append("Photo \(index + 1)\(labelSuffix(photo.label))")
            }
            return lines.joined(separator: "\n")
        case .pathInPrompt:
            if photos.count == 1 {
                return "Desk photo: \(photos[0].path)\(labelSuffix(photos[0].label)) (\(readInstruction))"
            }
            var lines = ["\(photos.count) desk photos (\(readInstruction); \(ordering)):"]
            for (index, photo) in photos.enumerated() {
                lines.append("\(index + 1). \(photo.path)\(labelSuffix(photo.label))")
            }
            return lines.joined(separator: "\n")
        }
    }

    /// 標註接在照片路徑後；未標註回空字串，輸出與未加此功能前一致。
    /// 標註是使用者的原話，不翻譯——模型自己看得懂。
    private static func labelSuffix(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : " (lighting scenario: \(trimmed))"
    }

    /// decode 失敗重試一次時附加的修正指示。
    public static let retryInstruction =
        "(The previous output could not be parsed as JSON matching the schema. "
        + "Output again: exactly one JSON object, with no other text and no fences.)"

    /// 固定小數位、不受 locale 影響的數字格式（"12"、"0.42"、"-0.30"）。
    private static func format(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: nil, value)
    }

    private static func formatSigned(_ value: Double) -> String {
        String(format: "%+.2f", locale: nil, value)
    }
}
