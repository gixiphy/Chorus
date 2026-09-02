/// 五個入口共用的請求格式（CLI、localhost HTTP、MCP、TestHooks、Scenes）。
///
/// `peer` 省略＝本機。給了就把整個請求轉發到那台 peer（走既有的 command
/// 通道），**本機不動作**——跨機是這一層的一等公民，不是另一條 API。
public struct ControlRequest: Codable, Sendable, Equatable, Hashable {
    public var verb: ControlVerb
    public var target: ControlTarget
    public var property: ControlProperty?
    /// 未解析的值字串；解析規則由 `property.valueKind` 決定。
    /// `perform` 時是動作的引數（例如場景名稱）。
    public var value: String?
    public var action: ControlAction?
    /// 已配對裝置的名稱（片段比對）。
    public var peer: String?
    /// 限時場景的時長（B7）：`25m`／`1h`／`90s`／裸秒數。
    ///
    /// **只有 `perform runScene` 可帶**——場景 ＋ 時長 ＝ 專注模式；省略就是
    /// 一般場景，套用後不會自動還原。
    ///
    /// 為什麼是 `runScene` 的修飾語而不是另一個 action：時長修飾的是「怎麼
    /// 套用這個場景」，不是另一件事。第二步的 Focus Filter 也要走同一條，
    /// 一個 action 兩種 shape 比兩個 action 好維護。
    ///
    /// Optional 且加在尾端，舊的 client 不送這個欄位——wire 相容。
    public var duration: String?

    public init(
        verb: ControlVerb,
        target: ControlTarget,
        property: ControlProperty? = nil,
        value: String? = nil,
        action: ControlAction? = nil,
        peer: String? = nil,
        duration: String? = nil
    ) {
        self.verb = verb
        self.target = target
        self.property = property
        self.value = value
        self.action = action
        self.peer = peer
        self.duration = duration
    }
}

/// 通過驗證的請求：動詞／屬性／目標種類相容，值已依屬性的種類解析完成。
/// executor 拿到這個型別就不需要再做任何格式檢查。
public struct ValidatedControlRequest: Sendable, Equatable {
    public let verb: ControlVerb
    public let target: ControlTarget
    public let property: ControlProperty?
    public let value: ControlValue?
    public let action: ControlAction?
    public let actionArgument: String?
    public let peer: String?
    /// 已解析的限時場景時長（秒，恆 > 0）。`nil` ＝ 一般場景。
    public let durationSeconds: Double?
}

public enum ControlRequestValidator {
    /// 純驗證：只看語法與相容性矩陣，**不碰任何硬體、不解析成實體**。
    /// `displayWithMouse` 在這裡永遠合法——它找不找得到螢幕是執行期的事。
    public static func validate(_ request: ControlRequest) throws(ControlError) -> ValidatedControlRequest {
        let duration = try validateDuration(request)
        switch request.verb {
        case .perform:
            guard let action = request.action else { throw ControlError.missingAction }
            return ValidatedControlRequest(
                verb: .perform,
                target: request.target,
                property: nil,
                value: nil,
                action: action,
                actionArgument: request.value,
                peer: request.peer,
                durationSeconds: duration
            )

        case .get:
            // 省略 property ＝ 讀取該目標的全部屬性（唯一的列舉入口）
            if let property = request.property {
                try check(property, verb: .get, target: request.target)
            }
            return ValidatedControlRequest(
                verb: .get,
                target: request.target,
                property: request.property,
                value: nil,
                action: nil,
                actionArgument: nil,
                peer: request.peer,
                durationSeconds: nil
            )

        case .toggle:
            guard let property = request.property else {
                throw ControlError.missingProperty(.toggle)
            }
            try check(property, verb: .toggle, target: request.target)
            return ValidatedControlRequest(
                verb: .toggle,
                target: request.target,
                property: property,
                value: nil,
                action: nil,
                actionArgument: nil,
                peer: request.peer,
                durationSeconds: nil
            )

        case .set:
            guard let property = request.property else {
                throw ControlError.missingProperty(.set)
            }
            try check(property, verb: .set, target: request.target)
            guard let raw = request.value else {
                throw ControlError.missingValue(property)
            }
            let value = try ControlValue.parse(raw, kind: property.valueKind)
            return ValidatedControlRequest(
                verb: .set,
                target: request.target,
                property: property,
                value: value,
                action: nil,
                actionArgument: nil,
                peer: request.peer,
                durationSeconds: nil
            )
        }
    }

    /// 時長的驗證。**時長只配 `perform runScene`**——帶在別的地方一律報錯
    /// 而不是靜靜忽略：使用者以為設了 25 分鐘、實際上沒有，是最糟的失敗形狀。
    private static func validateDuration(_ request: ControlRequest) throws(ControlError) -> Double? {
        guard let raw = request.duration else { return nil }
        guard request.verb == .perform, request.action == .runScene else {
            throw ControlError.badValue(
                raw, hint: "時長只能配 perform runScene（場景 ＋ 時長 ＝ 限時場景）"
            )
        }
        // `off`（0）與 `forever`（−1）在收值規則裡都合法，但限時場景需要一個
        // 會到期的時刻——「永遠不還原」就是一般場景，不該用時長表達
        guard case let .duration(seconds) = try ControlValue.parse(raw, kind: .duration),
              seconds > 0
        else {
            throw ControlError.badValue(raw, hint: "限時場景需要正的時長，例如 25m、1h、90s")
        }
        return seconds
    }

    private static func check(
        _ property: ControlProperty,
        verb: ControlVerb,
        target: ControlTarget
    ) throws(ControlError) {
        guard property.allowedVerbs.contains(verb) else {
            throw ControlError.verbNotAllowed(verb: verb, property: property)
        }
        guard property.targetKinds.contains(target.kind) else {
            throw ControlError.targetKindMismatch(property: property, target: target.stringValue)
        }
    }
}
