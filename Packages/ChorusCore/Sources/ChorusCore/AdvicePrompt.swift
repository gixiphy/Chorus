import Foundation

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

/// 光環境顧問的 prompt 與結構化輸出工具 schema。
/// 純字串組裝，輸出順序固定，可快照測試；API 呼叫本體在 app 層。
public enum AdvicePrompt {
    /// 強制呼叫的結構化輸出工具名（`tool_choice: {type: "tool"}`）。
    public static let toolName = "submit_lighting_advice"

    /// 系統提示。判讀重點與輸出紀律見設計文件 §3。
    public static let systemPrompt = """
    你是 Chorus（macOS 亮度／音量跨機同步 App）的顯示器調光顧問。使用者會提供一張\
    桌面佈置照片，以及各顯示器的清單（含節點在照片上的 0–1 正規化座標、亮度 backend、\
    目前差異值）與現行自動亮度參數。

    判讀重點：
    - 光源的類型與方位：窗戶、天花板燈、檯燈、螢幕掛燈，以及它們相對各螢幕的位置。
    - 各螢幕視野背景的亮度：背景亮的螢幕需要偏正的 offset 才不顯得暗。
    - 陰影帶與反光風險：層架遮蔭、掛燈或檯燈直射螢幕面。
    - 環境光感測器的位置：MacBook 的 ALS 在螢幕上緣瀏海附近，判斷它會被哪些光源影響、\
    讀值相對桌面整體是偏高或偏低。
    - 多張照片可能拍的是不同照明情境（有標註時會寫明是白天、夜晚或開了哪些燈）：\
    比對它們的差異，分辨哪些是恆常的擺設因素（層架遮蔭、螢幕朝向），哪些只是當下\
    開關燈造成的。照片是自動曝光的，畫面亮度不代表絕對照度，請以標註與 lux 統計為準。

    輸出紀律（一律透過 \(toolName) 工具回報，所有文字使用繁體中文）：
    - offset 是絕對建議值（非增量），起步幅度保守（|offset| ≤ 0.15）；使用者的手動修正\
    會由學習機制接手微調，不需要一次到位。
    - offset 是各螢幕之間的相對偏差，必須在所有照明情境下都成立；整體亮度隨環境變化\
    由 maxLux／minBrightness 曲線負責，不要用 offset 去補償單一情境的明暗。
    - backend 為 "gamma" 的螢幕只能軟體降亮、不能加亮：在 warnings 提醒使用者先用螢幕 \
    OSD 把硬體背光設到「最亮情境下舒適」的上限。
    - maxLux／minBrightness 只在照片與 lux 統計有明確依據時才提供；不確定的觀察寫進 \
    warnings，不要編造數值。
    - displayID 只能使用輸入清單中的值；同一顯示器最多一筆 offset 建議。
    """

    /// 工具 input_schema（JSON Schema），形狀與 `LightingAdvice` 的 Codable 對稱。
    /// 數值範圍與 `LightingAdvice` 的夾值範圍一致（schema 擋第一線，sanitized 保底）。
    public static let toolInputSchemaJSON = """
    {
      "type": "object",
      "properties": {
        "sceneSummary": {
          "type": "string",
          "description": "對照片光環境的整體描述（繁體中文，2–4 句）"
        },
        "offsets": {
          "type": "array",
          "items": {
            "type": "object",
            "properties": {
              "displayID": { "type": "string", "description": "必須來自輸入的顯示器清單" },
              "offset": { "type": "number", "minimum": -0.3, "maximum": 0.3 },
              "reason": { "type": "string", "description": "繁體中文一句話理由" }
            },
            "required": ["displayID", "offset", "reason"]
          }
        },
        "maxLux": { "type": "number", "minimum": 100, "maximum": 20000 },
        "minBrightness": { "type": "number", "minimum": 0, "maximum": 0.5 },
        "warnings": {
          "type": "array",
          "items": { "type": "string" },
          "description": "無套用動作的提醒（繁體中文）"
        }
      },
      "required": ["sceneSummary", "offsets", "warnings"]
    }
    """

    /// context → user message 的文字描述（照片以外的部分）。
    /// 顯示器依輸入順序列出，數字格式固定。
    public static func contextDescription(_ context: AdviceContext) -> String {
        var lines: [String] = ["顯示器清單："]
        for display in context.displays {
            var parts = [
                "- id=\(display.id)",
                "名稱=「\(display.name)」",
                "backend=\(display.backend)"
            ]
            if let position = display.normalizedPosition, position.count == 2 {
                parts.append("照片座標=(\(format(position[0], decimals: 2)), \(format(position[1], decimals: 2)))")
            } else {
                parts.append("照片座標=未擺放")
            }
            parts.append("目前offset=\(formatSigned(display.currentOffset))")
            lines.append(parts.joined(separator: " "))
        }
        lines.append(
            "現行曲線：minBrightness=\(format(context.curve.minBrightness, decimals: 2)) "
                + "maxLux=\(format(context.curve.maxLux, decimals: 0))"
        )
        if let lux = context.recentLux {
            lines.append(
                "近期環境光（lux）：min=\(format(lux.minLux, decimals: 0)) "
                    + "median=\(format(lux.medianLux, decimals: 0)) "
                    + "max=\(format(lux.maxLux, decimals: 0))"
            )
        } else {
            lines.append("近期環境光：無資料（本機無環境光感測器）")
        }
        if let hasLightBar = context.hasLightBarHint {
            lines.append(hasLightBar ? "使用者標注：桌面有螢幕掛燈" : "使用者標注：桌面沒有螢幕掛燈")
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
        readInstruction: String
    ) -> String {
        let photoLines: String
        if photos.count <= 1 {
            let entry = photos.first.map { $0.path + labelSuffix($0.label) } ?? "(無)"
            photoLines = "桌面照片：\(entry)（\(readInstruction)）"
        } else {
            var lines = ["桌面照片共 \(photos.count) 張（\(readInstruction)；第 1 張是配置圖背景照，顯示器座標以它為準，其餘為補充視角）："]
            for (index, photo) in photos.enumerated() {
                lines.append("\(index + 1). \(photo.path)\(labelSuffix(photo.label))")
            }
            photoLines = lines.joined(separator: "\n")
        }
        return """
        \(systemPrompt)

        \(contextDescription(context))

        \(photoLines)

        只輸出一個 JSON 物件（不要 markdown fence、不要其他文字），必須符合以下 JSON Schema：
        \(toolInputSchemaJSON)
        """
    }

    /// 標註接在照片路徑後；未標註回空字串，輸出與未加此功能前一致。
    private static func labelSuffix(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : "（照明情境：\(trimmed)）"
    }

    /// decode 失敗重試一次時附加的修正指示。
    public static let retryInstruction =
        "（上次輸出無法解析為符合 schema 的 JSON。請重新輸出：只輸出一個 JSON 物件，不含任何其他文字或 fence。）"

    /// 固定小數位、不受 locale 影響的數字格式（"12"、"0.42"、"-0.30"）。
    private static func format(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", locale: nil, value)
    }

    private static func formatSigned(_ value: Double) -> String {
        String(format: "%+.2f", locale: nil, value)
    }
}
