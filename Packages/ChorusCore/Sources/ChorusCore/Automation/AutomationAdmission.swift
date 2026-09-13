/// 本機 HTTP 自動化介面的限額（純邏輯；App 的連線層在背景 queue 上持有一份）。
///
/// 每一種資源都有上限：連線數、事件流數、單次批次的指令數、全域待處理指令數。
/// 待處理指令要等**真的執行完**才釋放——逾時回了 504 的指令仍佔著額度，
/// 主執行緒卡住時新指令直接 503，不在後面越堆越多。
public struct AutomationAdmission: Sendable {
    public struct Limits: Sendable, Equatable {
        public var maxConnections: Int
        public var maxEventStreams: Int
        public var maxBatch: Int
        public var maxPendingCommands: Int

        public init(maxConnections: Int = 16, maxEventStreams: Int = 4, maxBatch: Int = 64, maxPendingCommands: Int = 128) {
            self.maxConnections = maxConnections
            self.maxEventStreams = maxEventStreams
            self.maxBatch = maxBatch
            self.maxPendingCommands = maxPendingCommands
        }
    }

    public enum CommandRejection: Sendable, Equatable {
        case batchTooLarge(limit: Int)
        case overloaded
    }

    public let limits: Limits
    public private(set) var connections = 0
    public private(set) var eventStreams = 0
    public private(set) var pendingCommands = 0

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// 未認證的連線也算——限額在讀任何資料之前就生效。
    public mutating func admitConnection() -> Bool {
        guard connections < limits.maxConnections else { return false }
        connections += 1
        return true
    }

    public mutating func releaseConnection() {
        connections = max(0, connections - 1)
    }

    /// 事件流另有自己的上限（它同時也佔一條連線）。
    public mutating func admitEventStream() -> Bool {
        guard eventStreams < limits.maxEventStreams else { return false }
        eventStreams += 1
        return true
    }

    public mutating func releaseEventStream() {
        eventStreams = max(0, eventStreams - 1)
    }

    public mutating func admitCommands(_ count: Int) -> CommandRejection? {
        guard count <= limits.maxBatch else { return .batchTooLarge(limit: limits.maxBatch) }
        guard pendingCommands + count <= limits.maxPendingCommands else { return .overloaded }
        pendingCommands += count
        return nil
    }

    public mutating func releaseCommands(_ count: Int) {
        pendingCommands = max(0, pendingCommands - count)
    }
}

/// 單一事件流訂閱者還沒被網路層收下的量。對方讀太慢就斷線，重連後重讀 state——
/// 不默默丟事件還宣稱串流完整。
public struct EventStreamBacklog: Sendable, Equatable {
    public let maxEvents: Int
    public let maxBytes: Int
    public private(set) var events = 0
    public private(set) var bytes = 0

    public init(maxEvents: Int = 64, maxBytes: Int = 64 << 10) {
        self.maxEvents = maxEvents
        self.maxBytes = maxBytes
    }

    /// false ＝ 這一則放不下，呼叫端應關掉這個訂閱者。
    public mutating func reserve(bytes size: Int) -> Bool {
        guard events + 1 <= maxEvents, bytes + size <= maxBytes else { return false }
        events += 1
        bytes += size
        return true
    }

    public mutating func complete(bytes size: Int) {
        events = max(0, events - 1)
        bytes = max(0, bytes - size)
    }
}
