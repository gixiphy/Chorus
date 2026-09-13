public enum OperationOutcome: String, Sendable, CaseIterable {
    case success
    case failure
    case timeout
    case cancelled
}

/// 一種操作（例如 `cloud.write`）的累計。
public struct OperationStats: Sendable, Equatable {
    public var started = 0
    public var outcomes: [OperationOutcome: Int] = [:]
    /// 已完成的耗時分布。
    public var latency = LatencyHistogram()
    /// 目前還在進行中的數量；卡住的同步 I/O 會一直留在這裡。
    public var inFlight = 0
    public var inFlightHighWater = 0

    public init() {}

    public var completed: Int { latency.count }
}

/// 佇列深度這類「現值＋最高水位」的量。
public struct GaugeStats: Sendable, Equatable {
    public var current = 0
    public var highWater = 0

    public init() {}
}

/// 操作耗時、在途數與佇列深度的純帳本。App 端包一層鎖與時鐘。
///
/// **每一張表都有上限**：名稱數、在途 token 數。診斷資料本身不能無界成長——
/// 一個忘了 `end` 的呼叫點不該讓記憶體跟著漏。
public struct OperationLedger: Sendable {
    public struct Stall: Sendable, Equatable {
        public let token: UInt64
        public let name: String
        public let age: Duration
    }

    /// 名稱表滿之後新名稱都記在這裡。
    public static let overflowName = "other"

    public let maxNames: Int
    public let maxInFlight: Int
    public private(set) var operations: [String: OperationStats] = [:]
    public private(set) var gauges: [String: GaugeStats] = [:]
    /// 在途表滿時沒追蹤到的 begin 次數。
    public private(set) var untrackedBegins = 0

    private struct InFlight {
        let name: String
        let startedAt: Duration
        var stallReported = false
    }

    private var inFlight: [UInt64: InFlight] = [:]
    private var nextToken: UInt64 = 0

    public init(maxNames: Int = 64, maxInFlight: Int = 4_096) {
        self.maxNames = max(1, maxNames)
        self.maxInFlight = max(1, maxInFlight)
    }

    /// 開始一次操作。回傳 0 代表在途表已滿、這次不追蹤（照樣呼叫 `end`，會被忽略）。
    public mutating func begin(_ name: String, now: Duration) -> UInt64 {
        guard inFlight.count < maxInFlight else {
            untrackedBegins += 1
            return 0
        }
        let resolved = Self.resolve(name, existing: operations.keys, limit: maxNames)
        nextToken += 1
        inFlight[nextToken] = InFlight(name: resolved, startedAt: now)
        operations[resolved, default: OperationStats()].started += 1
        operations[resolved]!.inFlight += 1
        operations[resolved]!.inFlightHighWater = max(
            operations[resolved]!.inFlightHighWater, operations[resolved]!.inFlight
        )
        return nextToken
    }

    /// 結束一次操作。未知或重複結束的 token 回 nil、不影響統計。
    @discardableResult
    public mutating func end(
        _ token: UInt64,
        outcome: OperationOutcome,
        now: Duration
    ) -> (name: String, elapsed: Duration)? {
        guard let entry = inFlight.removeValue(forKey: token) else { return nil }
        let elapsed = max(.zero, now - entry.startedAt)
        operations[entry.name, default: OperationStats()].inFlight -= 1
        operations[entry.name]!.outcomes[outcome, default: 0] += 1
        operations[entry.name]!.latency.record(elapsed)
        return (entry.name, elapsed)
    }

    public mutating func adjustGauge(_ name: String, by delta: Int) {
        let resolved = Self.resolve(name, existing: gauges.keys, limit: maxNames)
        var gauge = gauges[resolved, default: GaugeStats()]
        gauge.current = max(0, gauge.current + delta)
        gauge.highWater = max(gauge.highWater, gauge.current)
        gauges[resolved] = gauge
    }

    /// 在途超過門檻、之前沒報過的操作。每個 token 只會回報一次。
    public mutating func collectNewStalls(now: Duration, threshold: Duration) -> [Stall] {
        var stalls: [Stall] = []
        for (token, entry) in inFlight where !entry.stallReported {
            let age = now - entry.startedAt
            guard age >= threshold else { continue }
            inFlight[token]?.stallReported = true
            stalls.append(Stall(token: token, name: entry.name, age: age))
        }
        return stalls.sorted { $0.token < $1.token }
    }

    /// 各操作最久的在途時間。
    public func oldestInFlightAge(now: Duration) -> [String: Duration] {
        var oldest: [String: Duration] = [:]
        for entry in inFlight.values {
            oldest[entry.name] = max(oldest[entry.name] ?? .zero, now - entry.startedAt)
        }
        return oldest
    }

    private static func resolve(
        _ name: String,
        existing: Dictionary<String, some Any>.Keys,
        limit: Int
    ) -> String {
        existing.contains(name) || existing.count < limit ? name : overflowName
    }
}
