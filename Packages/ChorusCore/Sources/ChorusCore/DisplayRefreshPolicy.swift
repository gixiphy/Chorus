/// 顯示變更刷新的排程決策：合併通知、喚醒絕對期限、進行中／待處理各一份。
///
/// 純資料＋決策；App 端負責真正的 sleep 與硬體 I/O。時鐘單位是呼叫端提供的
/// 單調 `Duration`（不含睡眠的偏移亦可，但喚醒期限應以「含睡眠」的時鐘延長，
/// 由呼叫端在 noteWake 時傳入正確的 now）。
public struct DisplayRefreshPolicy: Sendable, Equatable {
    public var coalesceWindow: Duration
    public var maxCoalesceDelay: Duration
    public var wakeSettle: Duration

    public init(
        coalesceWindow: Duration = .milliseconds(200),
        maxCoalesceDelay: Duration = .seconds(1),
        wakeSettle: Duration = .seconds(3)
    ) {
        self.coalesceWindow = coalesceWindow
        self.maxCoalesceDelay = maxCoalesceDelay
        self.wakeSettle = wakeSettle
    }

    public enum Reason: String, Hashable, Sendable, CaseIterable {
        case configurationBegan
        case topologyChanged
        case modeChanged
        case wake
        case unrecognizedAppKit
        case userForce
        case notification
    }

    public struct State: Sendable, Equatable {
        public var generation: UInt64 = 0
        /// 喚醒後 DDC／刷新最早可開始的時間（單調時鐘）。只延長、不縮短。
        public var wakeSettleUntil: Duration?
        public var inFlight = false
        public var pendingReasons: Set<Reason> = []
        public var pendingDisplayIDs: Set<UInt32> = []
        public var firstPendingAt: Duration?
        public var scheduledFireAt: Duration?

        public init() {}
    }

    public enum Action: Sendable, Equatable {
        case none
        /// 在 `at` 時刻觸發 `fire`（若已有更早排程則以回傳為準）。
        case schedule(at: Duration)
        case startRefresh(generation: UInt64, reasons: Set<Reason>, forceFull: Bool)
    }

    /// 螢幕喚醒：延長 settle 期限，並排一次刷新（不得早於期限）。
    public func noteWake(state: inout State, now: Duration) -> Action {
        let until = now + wakeSettle
        state.wakeSettleUntil = max(state.wakeSettleUntil ?? until, until)
        return noteEvent(state: &state, reason: .wake, displayIDs: [], now: now)
    }

    /// 合併一次顯示事件。進行中則只累積 pending；空閒則排程合併窗口。
    public func noteEvent(
        state: inout State,
        reason: Reason,
        displayIDs: Set<UInt32>,
        now: Duration
    ) -> Action {
        state.pendingReasons.insert(reason)
        state.pendingDisplayIDs.formUnion(displayIDs)
        if state.firstPendingAt == nil {
            state.firstPendingAt = now
        }

        if state.inFlight {
            state.scheduledFireAt = nil
            return .none
        }

        // debounce：每次事件把窗口往後推，但不得超過 firstPending + maxDelay；
        // 喚醒期限另取 max，一般通知無法縮短 wake settle。
        let earliest = earliestAllowedStart(state: state, now: now)
        let coalesceAt = now + coalesceWindow
        let maxAt = (state.firstPendingAt ?? now) + maxCoalesceDelay
        let fireAt = max(earliest, min(coalesceAt, maxAt))

        if state.scheduledFireAt == fireAt {
            return .none
        }
        state.scheduledFireAt = fireAt
        return .schedule(at: fireAt)
    }

    /// 排程到期：若仍空閒且有 pending，開始刷新並推進 generation。
    public func fire(state: inout State, now: Duration) -> Action {
        state.scheduledFireAt = nil
        guard !state.inFlight, !state.pendingReasons.isEmpty else { return .none }

        let earliest = earliestAllowedStart(state: state, now: now)
        if now < earliest {
            state.scheduledFireAt = earliest
            return .schedule(at: earliest)
        }

        state.generation &+= 1
        let reasons = state.pendingReasons
        let forceFull = reasons.contains(.userForce) || reasons.contains(.topologyChanged)
        state.pendingReasons = []
        state.pendingDisplayIDs = []
        state.firstPendingAt = nil
        state.inFlight = true
        return .startRefresh(generation: state.generation, reasons: reasons, forceFull: forceFull)
    }

    /// 刷新結束：若期間又累積了 pending，立刻排下一次（仍尊重 wake 期限）。
    public func refreshFinished(state: inout State, generation: UInt64, now: Duration) -> Action {
        guard generation == state.generation else { return .none }
        state.inFlight = false
        guard !state.pendingReasons.isEmpty else { return .none }
        let earliest = earliestAllowedStart(state: state, now: now)
        let fireAt = max(earliest, now)
        state.scheduledFireAt = fireAt
        return .schedule(at: fireAt)
    }

    public func earliestAllowedStart(state: State, now: Duration) -> Duration {
        max(now, state.wakeSettleUntil ?? now)
    }
}
