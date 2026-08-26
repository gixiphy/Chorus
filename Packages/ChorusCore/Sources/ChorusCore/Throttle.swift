/// slider 拖曳事件的節流決策（純邏輯，時間由呼叫端注入）。
/// 呼叫端負責在 `deferUntil` 到期時送出「最後一筆」pending 值（保證尾值）。
public struct Throttle: Sendable {
    public let intervalMillis: Int64
    private var lastSentMillis: [ControlKey: Int64] = [:]

    public init(intervalMillis: Int64 = 50) {
        self.intervalMillis = max(intervalMillis, 1)
    }

    public enum Decision: Equatable, Sendable {
        case sendNow
        /// 要求呼叫端在該時刻把最新 pending 值送出。
        case deferUntil(millis: Int64)
    }

    public mutating func shouldSend(key: ControlKey, nowMillis: Int64) -> Decision {
        if let last = lastSentMillis[key], nowMillis - last < intervalMillis {
            return .deferUntil(millis: last + intervalMillis)
        }
        lastSentMillis[key] = nowMillis
        return .sendNow
    }

    /// deferUntil 到期實際送出時呼叫，更新節流基準。
    public mutating func didSendDeferred(key: ControlKey, nowMillis: Int64) {
        lastSentMillis[key] = nowMillis
    }
}
