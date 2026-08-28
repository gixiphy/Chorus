/// 回應裡的值。JSON 要能同時裝數字、布林與字串（例如場景名稱）。
public enum ControlJSONValue: Codable, Sendable, Equatable, Hashable {
    case number(Double)
    case bool(Bool)
    case string(String)
    case null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else {
            self = .string(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

/// 單一實體的結果。`target` 是**解析後的實體名稱**（不是請求裡的意圖字串）——
/// `displayWithMouse` 打進去，回來的是「ASUS VS207」，呼叫端才知道動到了誰。
public struct ControlResult: Codable, Sendable, Equatable, Hashable {
    public var target: String
    public var property: String?
    public var value: ControlJSONValue?

    public init(target: String, property: String? = nil, value: ControlJSONValue? = nil) {
        self.target = target
        self.property = property
        self.value = value
    }
}

public struct ControlErrorPayload: Codable, Sendable, Equatable, Hashable {
    public var code: String
    public var message: String
    public var hint: String?

    public init(_ error: ControlError) {
        code = error.code
        message = error.message
        hint = error.hint
    }
}

public struct ControlResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var results: [ControlResult]?
    public var error: ControlErrorPayload?

    public static func success(_ results: [ControlResult]) -> ControlResponse {
        ControlResponse(ok: true, results: results, error: nil)
    }

    public static func failure(_ error: ControlError) -> ControlResponse {
        ControlResponse(ok: false, results: nil, error: ControlErrorPayload(error))
    }
}
