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

    public init(
        verb: ControlVerb,
        target: ControlTarget,
        property: ControlProperty? = nil,
        value: String? = nil,
        action: ControlAction? = nil,
        peer: String? = nil
    ) {
        self.verb = verb
        self.target = target
        self.property = property
        self.value = value
        self.action = action
        self.peer = peer
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
}

public enum ControlRequestValidator {
    /// 純驗證：只看語法與相容性矩陣，**不碰任何硬體、不解析成實體**。
    /// `displayWithMouse` 在這裡永遠合法——它找不找得到螢幕是執行期的事。
    public static func validate(_ request: ControlRequest) throws(ControlError) -> ValidatedControlRequest {
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
                peer: request.peer
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
                peer: request.peer
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
                peer: request.peer
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
                peer: request.peer
            )
        }
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
