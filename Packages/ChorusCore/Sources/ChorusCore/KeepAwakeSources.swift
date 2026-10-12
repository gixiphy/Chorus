import Foundation

/// 工作來源種類（spec §4.1）。
public enum KeepAwakeSourceKind: String, Sendable, Codable, CaseIterable {
    case agentActivity
    case orca
    case desktopApp
    case lease
    case appPresence
}

/// 來源健康狀態；不影響 busy 計算，只供顯示。
public enum KeepAwakeSourceHealth: Sendable, Equatable, Codable {
    case ok
    case degraded(reason: String)
    case unavailable(reason: String)

    private enum CodingKeys: String, CodingKey {
        case kind, reason
    }

    private enum Kind: String, Codable {
        case ok, degraded, unavailable
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .ok:
            self = .ok
        case .degraded:
            self = .degraded(reason: try container.decode(String.self, forKey: .reason))
        case .unavailable:
            self = .unavailable(reason: try container.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ok:
            try container.encode(Kind.ok, forKey: .kind)
        case let .degraded(reason):
            try container.encode(Kind.degraded, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        case let .unavailable(reason):
            try container.encode(Kind.unavailable, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// 單一工作來源的報告。
public struct KeepAwakeSourceReport: Sendable, Equatable, Codable, Identifiable {
    /// 穩定 id：`"agents"`、`"orca"`、`"desktop.codex"`、`"lease:<id>"`、`"app:grok-bot"` 等。
    public var id: String
    public var kind: KeepAwakeSourceKind
    /// 選單與通知直接顯示的名稱（已在地化）。
    public var displayName: String
    /// 補充說明；nil 表示不顯示。
    public var detail: String?
    /// 現在是否「正在」工作。true 時不套用寬限。
    public var isWorkingNow: Bool
    /// 最後一次有工作跡證的時刻（wall clock）。
    public var lastWorkingAt: Date?
    public var health: KeepAwakeSourceHealth

    public init(
        id: String,
        kind: KeepAwakeSourceKind,
        displayName: String,
        detail: String? = nil,
        isWorkingNow: Bool,
        lastWorkingAt: Date? = nil,
        health: KeepAwakeSourceHealth = .ok
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.detail = detail
        self.isWorkingNow = isWorkingNow
        self.lastWorkingAt = lastWorkingAt
        self.health = health
    }
}

/// 所有來源聚合後的忙碌狀態。
public struct KeepAwakeBusyState: Sendable, Equatable {
    public var isBusy: Bool
    /// 讓 Mac 保持清醒的來源：正在工作或仍在寬限內。
    /// 順序：先放 `isWorkingNow`，再依 `lastWorkingAt` 由新到舊。
    public var contributing: [KeepAwakeSourceReport]
    /// 全部閒置時預計何時解除；`isBusy == false` 或仍有 `isWorkingNow` 時為 nil。
    public var releaseAt: Date?

    public init(isBusy: Bool, contributing: [KeepAwakeSourceReport], releaseAt: Date?) {
        self.isBusy = isBusy
        self.contributing = contributing
        self.releaseAt = releaseAt
    }
}

/// 多來源 OR ＋ 寬限的純聚合器（spec §4.1）。
public enum KeepAwakeBusyAggregator {
    public static let defaultGraceSeconds: Double = AgentActivityPlanner.defaultGraceSeconds

    public static func evaluate(
        _ reports: [KeepAwakeSourceReport],
        now: Date,
        graceSeconds: Double = defaultGraceSeconds
    ) -> KeepAwakeBusyState {
        let grace = Self.normalizedGrace(graceSeconds)
        let contributing = reports.filter { Self.isContributing($0, now: now, graceSeconds: grace) }
            .sorted(by: Self.contributeSort)

        let isBusy = !contributing.isEmpty
        let anyWorkingNow = contributing.contains(where: \.isWorkingNow)
        let releaseAt: Date?
        if isBusy, !anyWorkingNow {
            let latest = contributing.compactMap(\.lastWorkingAt).max()
            releaseAt = latest.map { $0.addingTimeInterval(grace) }
        } else {
            releaseAt = nil
        }

        return KeepAwakeBusyState(isBusy: isBusy, contributing: contributing, releaseAt: releaseAt)
    }

    /// 一份 report 算 contributing：`isWorkingNow`，或 `lastWorkingAt` 在寬限內。
    /// 未來時間戳當成剛剛發生（與 `AgentActivityPlanner` 相同）。
    ///
    /// 注意：同一份未變動的未來 mtime 不應每 tick 重設寬限——那是來源層（C07）
    /// 第一次觀察時 clamp 的責任；此處只看傳入的值。
    private static func isContributing(
        _ report: KeepAwakeSourceReport,
        now: Date,
        graceSeconds: Double
    ) -> Bool {
        if report.isWorkingNow { return true }
        guard let last = report.lastWorkingAt else { return false }
        return now.timeIntervalSince(last) < graceSeconds
    }

    private static func contributeSort(_ a: KeepAwakeSourceReport, _ b: KeepAwakeSourceReport) -> Bool {
        if a.isWorkingNow != b.isWorkingNow {
            return a.isWorkingNow && !b.isWorkingNow
        }
        switch (a.lastWorkingAt, b.lastWorkingAt) {
        case let (la?, lb?):
            if la != lb { return la > lb }
            return a.id < b.id
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return a.id < b.id
        }
    }

    private static func normalizedGrace(_ graceSeconds: Double) -> Double {
        guard graceSeconds.isFinite, graceSeconds >= 0 else {
            return defaultGraceSeconds
        }
        return graceSeconds
    }
}
