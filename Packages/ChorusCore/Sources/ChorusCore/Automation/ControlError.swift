/// 自動化介面的錯誤。**每一種都帶 hint**——這是這層 API 相對一般 REST
/// 的關鍵差異：LLM 看到 hint 就能自己重下一次正確的請求，不需要人介入。
/// 「找不到 DELL」沒有用，「找不到 DELL，目前有 Built-in、ASUS VS207」才有用。
///
/// 文案跟著 App 介面語言走：`String(localized:)` 查 `Bundle.main` 的 catalog
/// （在 App 內就是 Localizable.xcstrings；CLI／測試沒有 catalog 就回原文）。
/// 這裡的 key 由 scripts/strings-sync.py 用正規式從原始碼抽，**插值只能是 String**。
public enum ControlError: Error, Sendable, Equatable, Hashable {
    case unknownVerb(String)
    case unknownProperty(String)
    case unknownTarget(String)
    case unknownAction(String)
    /// 語法合法但現場找不到對應實體（執行期才知道）。
    case targetNotFound(String, hint: String)
    case verbNotAllowed(verb: ControlVerb, property: ControlProperty)
    case targetKindMismatch(property: ControlProperty, target: String)
    case badValue(String, hint: String)
    case missingValue(ControlProperty)
    case missingProperty(ControlVerb)
    case missingAction
    case unsupported(String)
    case peerNotFound(String, hint: String)
    case peerOffline(String)

    /// 機器可讀的錯誤碼（HTTP／MCP 回應與 CLI 結束碼都用它分類）。
    public var code: String {
        switch self {
        case .unknownVerb: "unknownVerb"
        case .unknownProperty: "unknownProperty"
        case .unknownTarget: "unknownTarget"
        case .unknownAction: "unknownAction"
        case .targetNotFound: "targetNotFound"
        case .verbNotAllowed: "verbNotAllowed"
        case .targetKindMismatch: "targetKindMismatch"
        case .badValue: "badValue"
        case .missingValue: "missingValue"
        case .missingProperty: "missingProperty"
        case .missingAction: "missingAction"
        case .unsupported: "unsupported"
        case .peerNotFound: "peerNotFound"
        case .peerOffline: "peerOffline"
        }
    }

    public var message: String {
        switch self {
        case let .unknownVerb(text):
            String(localized: "沒有「\(text)」這個動詞")
        case let .unknownProperty(text):
            String(localized: "沒有「\(text)」這個屬性")
        case let .unknownTarget(text):
            String(localized: "無法解析的目標「\(text)」")
        case let .unknownAction(text):
            String(localized: "沒有「\(text)」這個動作")
        case let .targetNotFound(text, _):
            String(localized: "找不到符合「\(text)」的裝置")
        case let .verbNotAllowed(verb, property):
            String(localized: "\(property.rawValue) 不支援 \(verb.rawValue)")
        case let .targetKindMismatch(property, target):
            String(localized: "\(property.rawValue) 不能套用在「\(target)」上")
        case let .badValue(text, _):
            String(localized: "無法解析的值「\(text)」")
        case let .missingValue(property):
            String(localized: "set \(property.rawValue) 需要一個值")
        case let .missingProperty(verb):
            String(localized: "\(verb.rawValue) 需要指定屬性")
        case .missingAction:
            String(localized: "perform 需要指定動作")
        case let .unsupported(detail):
            detail
        case let .peerNotFound(name, _):
            String(localized: "找不到名稱包含「\(name)」的已配對裝置")
        case let .peerOffline(name):
            String(localized: "「\(name)」目前沒有連線")
        }
    }

    public var hint: String? {
        switch self {
        case .unknownVerb:
            String(localized: "可用動詞：") + ControlVerb.allCases.map(\.rawValue).joined(separator: String(localized: "、"))
        case .unknownProperty:
            String(localized: "可用屬性：") + ControlProperty.allCases.map(\.rawValue).joined(separator: String(localized: "、"))
        case .unknownTarget:
            String(localized: "可用語法：") + ControlTarget.syntaxHint
        case .unknownAction:
            String(localized: "可用動作：") + ControlAction.allCases.map(\.rawValue).joined(separator: String(localized: "、"))
        case let .targetNotFound(_, hint):
            hint
        case let .verbNotAllowed(_, property):
            String(localized: "\(property.rawValue) 支援：") + property.allowedVerbs
                .map(\.rawValue).sorted().joined(separator: String(localized: "、"))
        case let .targetKindMismatch(property, _):
            String(localized: "\(property.rawValue) 只能套用在：\(property.targetKindsHint)")
        case let .badValue(_, hint):
            hint
        case let .missingValue(property):
            switch property.valueKind {
            case .unitInterval: String(localized: "例如 0.8、80% 或 +10%")
            // per-app 可以到 400%；裝置音量在 executor 那層才夾回 100%
            case .gain: String(localized: "例如 0.8、80%、+10%（逐 App 最高 400%）")
            case .signedUnit: String(localized: "例如 -0.2 或 15%")
            case .boolean: String(localized: "on 或 off")
            case .duration: String(localized: "off、30m、1h 或 forever")
            case .rawCode: String(localized: "整數 MCCS 代碼，例如 17 或 0x11")
            }
        case .missingProperty:
            String(localized: "可用屬性：") + ControlProperty.allCases.map(\.rawValue).joined(separator: String(localized: "、"))
        case .missingAction:
            String(localized: "可用動作：") + ControlAction.allCases.map(\.rawValue).joined(separator: String(localized: "、"))
        case .unsupported:
            nil
        case let .peerNotFound(_, hint):
            hint
        case .peerOffline:
            String(localized: "等對方上線後再試，或改用本機目標")
        }
    }
}
