/// 目標的大類。屬性與目標的相容性靠它比對
/// （亮度不能套在音訊裝置上、音量不能套在螢幕上）。
public enum ControlTargetKind: String, Codable, Sendable, Hashable {
    case display
    case audioDevice
    case system
    /// per-app 音訊（B6-6）。
    case app
}

/// 控制目標。**這是意圖不是實體**——`displayWithMouse` 要等執行時才知道
/// 是哪一台，因此解析（ChorusCore，純函式）與解析成實體（app 端 executor）
/// 是分開的兩件事。混在一起會逼純邏輯層去碰 NSEvent，整層就測不了了。
public enum ControlTarget: Sendable, Equatable, Hashable {
    case display(name: String)
    case displayLike(String)
    case displayUUID(String)
    case displayWithMouse
    case displayWithFocus
    case builtinDisplay
    case allDisplays

    case device(name: String)
    case deviceLike(String)
    case deviceUID(String)
    case defaultOutput
    case allDevices

    /// 整機層級（防睡眠、自動亮度、場景）。
    case system

    /// per-app 音量／靜音（B6-6）。`app:` 精確定位不要求 App 正在跑
    /// ——先設定好、App 一開就生效；`appLike:` 只比對現在有音訊的 App。
    case app(bundleID: String)
    case appLike(String)
    /// 列舉：目前有音訊的 App ＋ 已被調整過的 App。
    /// **這是 LLM 的入口**——沒有它，遙控端只能用猜的去湊 bundle id。
    case allApps

    public var kind: ControlTargetKind {
        switch self {
        case .display, .displayLike, .displayUUID, .displayWithMouse,
             .displayWithFocus, .builtinDisplay, .allDisplays:
            .display
        case .device, .deviceLike, .deviceUID, .defaultOutput, .allDevices:
            .audioDevice
        case .system:
            .system
        case .app, .appLike, .allApps:
            .app
        }
    }

    /// 這個目標可能對應多個實體（影響回應是單筆還是陣列）。
    public var isPlural: Bool {
        switch self {
        case .allDisplays, .allDevices, .allApps, .displayLike, .deviceLike, .appLike: true
        default: false
        }
    }
}

// MARK: - 字串語法

public extension ControlTarget {
    /// 無參數的具名目標。
    private static let bareTargets: [String: ControlTarget] = [
        "displaywithmouse": .displayWithMouse,
        "displaywithfocus": .displayWithFocus,
        "builtindisplay": .builtinDisplay,
        "alldisplays": .allDisplays,
        "defaultoutput": .defaultOutput,
        "alldevices": .allDevices,
        "allapps": .allApps,
        "system": .system,
    ]

    /// `<kind>:<argument>` 或無參數的具名目標。
    ///
    /// 只切**第一個**冒號：裝置名稱本身可能含冒號，`displayLike:Dell: U2720`
    /// 的引數應該是 `Dell: U2720` 而不是解析失敗。
    static func parse(_ text: String) -> ControlTarget? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let separator = trimmed.firstIndex(of: ":") else {
            return bareTargets[trimmed.lowercased()]
        }
        let kind = trimmed[trimmed.startIndex..<separator].lowercased()
        let argument = String(trimmed[trimmed.index(after: separator)...])
            .trimmingCharacters(in: .whitespaces)
        guard !argument.isEmpty else { return nil }
        return switch kind {
        case "display": .display(name: argument)
        case "displaylike": .displayLike(argument)
        case "displayuuid": .displayUUID(argument)
        case "device": .device(name: argument)
        case "devicelike": .deviceLike(argument)
        case "deviceuid": .deviceUID(argument)
        case "app": .app(bundleID: argument)
        case "applike": .appLike(argument)
        default: nil
        }
    }

    var stringValue: String {
        switch self {
        case let .display(name): "display:\(name)"
        case let .displayLike(text): "displayLike:\(text)"
        case let .displayUUID(uuid): "displayUUID:\(uuid)"
        case .displayWithMouse: "displayWithMouse"
        case .displayWithFocus: "displayWithFocus"
        case .builtinDisplay: "builtinDisplay"
        case .allDisplays: "allDisplays"
        case let .device(name): "device:\(name)"
        case let .deviceLike(text): "deviceLike:\(text)"
        case let .deviceUID(uid): "deviceUID:\(uid)"
        case .defaultOutput: "defaultOutput"
        case .allDevices: "allDevices"
        case .system: "system"
        case let .app(bundleID): "app:\(bundleID)"
        case let .appLike(text): "appLike:\(text)"
        case .allApps: "allApps"
        }
    }

    /// 錯誤訊息裡列給使用者／LLM 看的可用目標語法。
    static var syntaxHint: String {
        String(localized: "display:<名稱>、displayLike:<片段>、displayUUID:<uuid>、displayWithMouse、displayWithFocus、builtinDisplay、allDisplays、device:<名稱>、deviceLike:<片段>、deviceUID:<uid>、defaultOutput、allDevices、app:<bundle id>、appLike:<片段>、allApps、system")
    }
}

extension ControlTarget: Codable {
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = ControlTarget.parse(text) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "無法解析的目標「\(text)」。可用語法：\(ControlTarget.syntaxHint)"
            ))
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}
