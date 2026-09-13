/// 記憶體壓力降級的狀態機（純邏輯；時間由呼叫端注入）。
///
/// 系統的記憶體壓力事件只在**轉換**時送來。升級（normal → warning → critical）
/// 立刻生效；降級要等系統回報的等級**連續維持 `recovery` 這麼久**才跟著降——
/// 壓力在門檻附近抖動時，不會一下暫停一下恢復，把延後的工作全部擠在同一刻跑。
public struct MemoryPressureGovernor: Sendable {
    public enum Level: Int, Sendable, Comparable, CaseIterable {
        case normal
        case warning
        case critical

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public let recovery: Duration
    /// 系統最近一次回報的等級。
    public private(set) var reported: Level = .normal
    /// 呼叫端應該依據的等級（含恢復期）。
    public private(set) var effective: Level = .normal
    private var calmSince: Duration?

    public init(recovery: Duration = .seconds(30)) {
        self.recovery = recovery
    }

    /// 系統回報一次等級。回傳新的 `effective`（沒變回 nil）。
    public mutating func report(_ level: Level, now: Duration) -> Level? {
        reported = level
        if level > effective {
            effective = level
            calmSince = nil
            return level
        }
        if level < effective {
            // 開始（或延續）恢復期；已經在算就不重算，抖回同一個低等級不延長
            if calmSince == nil { calmSince = now }
        } else {
            calmSince = nil
        }
        return nil
    }

    /// 定期呼叫。恢復期滿就降到系統回報的等級。回傳新的 `effective`（沒變回 nil）。
    public mutating func tick(now: Duration) -> Level? {
        guard reported < effective, let calmSince, now - calmSince >= recovery else { return nil }
        effective = reported
        self.calmSince = nil
        return effective
    }

    /// 還在恢復期或壓力中，需要定期 `tick`。
    public var needsTicks: Bool { reported < effective }
}
