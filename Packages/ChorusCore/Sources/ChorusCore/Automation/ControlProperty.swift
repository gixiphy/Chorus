/// 屬性的值種類，決定 `ControlValue` 怎麼解析同一段文字。
public enum ControlValueKind: String, Codable, Sendable, Hashable {
    /// 0–1；百分比與 offset 皆收（見 ControlValue 的收值規則）。
    case unitInterval
    /// -0.5…+0.5 的差異值（ambientOffset）。
    case signedUnit
    case boolean
    /// `off` / `30m` / `1h` / `90s` / `forever`。
    case duration
    /// 整數 MCCS 代碼，不做任何比例換算（input 專用）。
    case rawCode
}

/// 可控制的屬性。**新增一個屬性只要改這個 enum，五個入口自動有**——
/// 這是整層設計的目的。
public enum ControlProperty: String, Codable, Sendable, CaseIterable, Hashable {
    case brightness
    case volume
    case mute
    case contrast
    case input
    case power
    case keepAwake
    case autoBrightness
    case ambientOffset

    public var valueKind: ControlValueKind {
        switch self {
        case .brightness, .volume, .contrast: .unitInterval
        case .mute, .power, .autoBrightness: .boolean
        case .input: .rawCode
        case .keepAwake: .duration
        case .ambientOffset: .signedUnit
        }
    }

    public var allowedVerbs: Set<ControlVerb> {
        switch self {
        // 輸入源是動作型 VCP：讀回來的值不可信（螢幕按鈕、另一台機器都會改），
        // 與 DisplayManager.setInput 的 one-shot 紀律一致——不提供 get。
        case .input: [.set]
        case .mute, .power, .keepAwake, .autoBrightness: [.get, .set, .toggle]
        case .brightness, .volume, .contrast, .ambientOffset: [.get, .set]
        }
    }

    public var targetKinds: Set<ControlTargetKind> {
        switch self {
        case .brightness, .contrast, .input, .power: [.display]
        case .volume, .mute: [.audioDevice, .app]
        case .keepAwake, .autoBrightness: [.system]
        case .ambientOffset: [.display, .system]
        }
    }

    /// 錯誤訊息用：這個屬性接受哪些目標。
    var targetKindsHint: String {
        targetKinds
            .map { kind in
                switch kind {
                case .display: "顯示器"
                case .audioDevice: "音訊裝置"
                case .system: "system（整機）"
                case .app: "app（尚未啟用）"
                }
            }
            .sorted()
            .joined(separator: "、")
    }
}
