import Foundation

/// Orca 工作樹狀態解碼與判定（spec §4.3、§14.3；R01 Q3–Q5）。
///
/// 純邏輯：不執行行程、不讀檔案。已知常數來自 R01 實查。
public enum OrcaWorktreeStatus {
    /// R01 Q3：Mac mini 實查 `com.stablyai.orca`（Team `6CX3WHS9HZ`）。
    public static let knownBundleIDs: Set<String> = ["com.stablyai.orca"]

    /// R01 Q3：Developer Team ID（驗簽／文件用；C07 不讀 Orca 檔案）。
    public static let teamID = "6CX3WHS9HZ"

    /// R01 Q4：CLI 候選（不依賴 PATH；GUI App 的 PATH 不含 Homebrew）。
    public static let defaultCLICandidates: [String] = [
        "/opt/homebrew/bin/orca",
        "/usr/local/bin/orca",
        "~/.local/bin/orca",
        "/Applications/Orca.app/Contents/Resources/bin/orca",
    ]

    /// R01 Q3：主 App 路徑（bundle 偵測用）。
    public static let knownAppPaths: Set<String> = [
        "/Applications/Orca.app",
    ]
}

// MARK: - Status value

public enum OrcaWorktreeStatusValue: Sendable, Equatable, Hashable {
    case active
    case working
    case permission
    case done
    case inactive
    case unknown(String)

    public init(rawValue: String) {
        switch rawValue {
        case "active": self = .active
        case "working": self = .working
        case "permission": self = .permission
        case "done": self = .done
        case "inactive": self = .inactive
        default: self = .unknown(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .active: return "active"
        case .working: return "working"
        case .permission: return "permission"
        case .done: return "done"
        case .inactive: return "inactive"
        case let .unknown(value): return value
        }
    }
}

extension OrcaWorktreeStatusValue: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Response

public struct OrcaWorktreePsResponse: Decodable, Sendable, Equatable {
    public var ok: Bool
    public var result: ResultPayload?
    public var error: ErrorBody?

    public struct ErrorBody: Decodable, Sendable, Equatable {
        public var code: String?
        public var message: String?

        public init(code: String? = nil, message: String? = nil) {
            self.code = code
            self.message = message
        }
    }

    public struct ResultPayload: Decodable, Sendable, Equatable {
        public var worktrees: [Row]
        public var totalCount: Int?
        public var truncated: Bool?

        public init(worktrees: [Row], totalCount: Int? = nil, truncated: Bool? = nil) {
            self.worktrees = worktrees
            self.totalCount = totalCount
            self.truncated = truncated
        }
    }

    public struct Row: Decodable, Sendable, Equatable {
        /// 穩定識別：優先 `worktreeId`，其次 `id`／`path`。
        public var id: String?
        public var name: String?
        public var path: String?
        public var status: OrcaWorktreeStatusValue
        public var lastActivityAt: Date?
        public var liveTerminalCount: Int?

        public init(
            id: String? = nil,
            name: String? = nil,
            path: String? = nil,
            status: OrcaWorktreeStatusValue,
            lastActivityAt: Date? = nil,
            liveTerminalCount: Int? = nil
        ) {
            self.id = id
            self.name = name
            self.path = path
            self.status = status
            self.lastActivityAt = lastActivityAt
            self.liveTerminalCount = liveTerminalCount
        }

        private enum CodingKeys: String, CodingKey {
            case worktreeId, id, path, displayName, name, status, lastActivityAt, liveTerminalCount
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let worktreeId = try container.decodeIfPresent(String.self, forKey: .worktreeId)
            let rawID = try container.decodeIfPresent(String.self, forKey: .id)
            let path = try container.decodeIfPresent(String.self, forKey: .path)
            self.path = path
            self.id = firstNonEmpty(worktreeId, rawID, path)
            let displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
            let name = try container.decodeIfPresent(String.self, forKey: .name)
            self.name = firstNonEmpty(displayName, name)
            if let status = try container.decodeIfPresent(OrcaWorktreeStatusValue.self, forKey: .status) {
                self.status = status
            } else {
                self.status = .unknown("")
            }
            self.lastActivityAt = Self.decodeLastActivity(from: container)
            self.liveTerminalCount = try container.decodeIfPresent(Int.self, forKey: .liveTerminalCount)
        }

        private static func decodeLastActivity(
            from container: KeyedDecodingContainer<CodingKeys>
        ) -> Date? {
            if let string = try? container.decode(String.self, forKey: .lastActivityAt) {
                return ISO8601Parsing.date(from: string)
            }
            if let millis = try? container.decode(Double.self, forKey: .lastActivityAt) {
                return dateFromEpochMillis(millis)
            }
            if let millis = try? container.decode(Int64.self, forKey: .lastActivityAt) {
                return dateFromEpochMillis(Double(millis))
            }
            if let millis = try? container.decode(Int.self, forKey: .lastActivityAt) {
                return dateFromEpochMillis(Double(millis))
            }
            return nil
        }

        private static func dateFromEpochMillis(_ millis: Double) -> Date? {
            guard millis.isFinite else { return nil }
            // Contract: numeric lastActivityAt is epoch milliseconds (§4.3).
            return Date(timeIntervalSince1970: millis / 1_000)
        }
    }

    public init(ok: Bool, result: ResultPayload? = nil, error: ErrorBody? = nil) {
        self.ok = ok
        self.result = result
        self.error = error
    }
}

// MARK: - Classification

public enum OrcaClassification: Sendable, Equatable {
    /// `qualityWarning`：§14.3 未知 status 等品質提示；有 working 證據時仍為 working，供 C07 對應 degraded。
    case working(rows: [OrcaWorktreePsResponse.Row], qualityWarning: String?)
    case idle
    /// §14.3：truncated 無 working、或含未知 status 且無 working —— 不能宣稱完整 idle。
    case incomplete(reason: String)
    case failed(reason: String)
}

public enum OrcaActivityPlanner {
    /// Allowlisted `error.code` values that may appear in a sanitized failure reason.
    /// Arbitrary CLI message／code text must never be forwarded (§14.3).
    public static let allowlistedFailureCodes: Set<String> = [
        "RUNTIME_UNAVAILABLE",
    ]

    /// Fixed §14.3 quality hint when any row has an unknown status.
    public static let unknownStatusWarning = "unknown status present"

    /// 判定一份 `orca worktree ps --json` 回應是否代表工作中。
    ///
    /// - `working` 一律算工作中。
    /// - `permission` 僅在 `countPermissionAsWorking == true` 時算（預設 true，Fi A3）。
    /// - `active`／`done`／`inactive` 不算工作中（`active` 只表示有活著的 PTY）。
    /// - `truncated == true` 且回傳列中沒有工作證據 → `.incomplete`（§14.3），不是 idle。
    /// - 任一 `unknown` status、且無 working 證據 → `.incomplete`（不猜 working）。
    /// - 有 working 證據且含 `unknown` → `.working` 並附 `qualityWarning`（不把 unknown 當 working）。
    public static func classify(
        _ response: OrcaWorktreePsResponse,
        countPermissionAsWorking: Bool
    ) -> OrcaClassification {
        guard response.ok else {
            return .failed(reason: sanitizedFailureReason(for: response.error))
        }
        guard let result = response.result else {
            return .failed(reason: "missing result")
        }

        let rows = result.worktrees
        let workingRows = rows.filter { isWorkingStatus($0.status, countPermission: countPermissionAsWorking) }
        let hasUnknown = rows.contains { row in
            if case .unknown = row.status { return true }
            return false
        }

        if !workingRows.isEmpty {
            let warning = hasUnknown ? unknownStatusWarning : nil
            return .working(rows: workingRows, qualityWarning: warning)
        }

        let truncated = result.truncated == true
        if truncated {
            return .incomplete(reason: "truncated without working evidence")
        }
        if hasUnknown {
            return .incomplete(reason: unknownStatusWarning)
        }
        return .idle
    }

    /// Sanitized `.failed` reason：fixed category or allowlisted code only（§14.3）。
    public static func sanitizedFailureReason(
        for error: OrcaWorktreePsResponse.ErrorBody?
    ) -> String {
        if let code = error?.code, allowlistedFailureCodes.contains(code) {
            return "orca:\(code)"
        }
        if error != nil {
            return "orca error"
        }
        return "ok=false"
    }

    /// 列是否算「工作中」狀態（不含 truncated／ok 檢查）。
    public static func isWorkingStatus(
        _ status: OrcaWorktreeStatusValue,
        countPermission: Bool
    ) -> Bool {
        switch status {
        case .working:
            return true
        case .permission:
            return countPermission
        case .active, .done, .inactive, .unknown:
            return false
        }
    }

    /// 從 JSON 字串解碼；失敗回 `nil`（呼叫端視為 `.failed`）。
    public static func decodeResponse(from json: String) -> OrcaWorktreePsResponse? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(OrcaWorktreePsResponse.self, from: data)
    }

    /// 解碼後分類；JSON 壞掉 → `.failed`。
    public static func classifyJSON(
        _ json: String,
        countPermissionAsWorking: Bool
    ) -> OrcaClassification {
        guard let response = decodeResponse(from: json) else {
            return .failed(reason: "malformed JSON")
        }
        return classify(response, countPermissionAsWorking: countPermissionAsWorking)
    }
}

// MARK: - Helpers

private enum ISO8601Parsing {
    static func date(from string: String) -> Date? {
        // Local formatters avoid non-Sendable static ISO8601DateFormatter (Swift 6).
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

private func firstNonEmpty(_ values: String?...) -> String? {
    for value in values {
        if let value, !value.isEmpty { return value }
    }
    return nil
}
