/// 主迴圈回應探測的純邏輯。時間由呼叫端注入（單調時鐘上的 Duration），
/// App 端的 watchdog 只負責計時器與投遞。
///
/// 背景計時器每拍呼叫 `tick`：沒有待回應的探針就發一支（呼叫端投遞到主執行緒，
/// 執行時呼叫 `answer`），有的話只檢查它等了多久。**同時最多一支探針**——
/// 主執行緒卡住時探針不會越堆越多，探測本身不會變成新的負擔。
public struct MainLoopProbe: Sendable {
    public struct Thresholds: Sendable, Equatable {
        /// 超過就算一次延遲（lag）。
        public var lag: Duration
        /// 超過就算一次卡住（hang），並在卡住當下與恢復時各報一次。
        public var hang: Duration

        public init(lag: Duration = .milliseconds(500), hang: Duration = .seconds(2)) {
            self.lag = lag
            self.hang = hang
        }
    }

    public enum Event: Sendable, Equatable {
        /// 探針等超過 hang 門檻、主執行緒仍未回應。每次卡住只報一次。
        case hangBegan(pendingFor: Duration)
        /// 卡住後終於回應；`stall` 是這支探針的總等待時間。
        case hangEnded(stall: Duration)
    }

    public struct Summary: Sendable, Equatable {
        public var latency = LatencyHistogram()
        public var lagCount = 0
        public var hangCount = 0
        public var longestStall: Duration = .zero

        public init() {}
    }

    public let thresholds: Thresholds
    /// 啟動以來的累計。
    public private(set) var lifetime = Summary()
    /// 上次 `takeWindow` 之後的區間（定期摘要用）。
    public private(set) var window = Summary()

    private struct Pending {
        let id: UInt64
        let postedAt: Duration
        var hangReported: Bool
    }

    private var pending: Pending?
    private var nextID: UInt64 = 0

    public init(thresholds: Thresholds = Thresholds()) {
        self.thresholds = thresholds
    }

    /// 計時器的一拍。回傳要投遞的探針 id（nil ＝ 上一支還沒回來）與事件。
    public mutating func tick(now: Duration) -> (probe: UInt64?, events: [Event]) {
        if var current = pending {
            let age = now - current.postedAt
            guard !current.hangReported, age >= thresholds.hang else { return (nil, []) }
            current.hangReported = true
            pending = current
            lifetime.hangCount += 1
            window.hangCount += 1
            return (nil, [.hangBegan(pendingFor: age)])
        }
        nextID += 1
        pending = Pending(id: nextID, postedAt: now, hangReported: false)
        return (nextID, [])
    }

    /// 主執行緒執行到探針。過期的 id（已被 `discardPending` 丟掉）忽略。
    public mutating func answer(probe id: UInt64, now: Duration) -> [Event] {
        guard let current = pending, current.id == id else { return [] }
        pending = nil
        let latency = max(.zero, now - current.postedAt)
        let isHang = latency >= thresholds.hang
        // 計時器也被餓到、沒來得及在卡住期間報 hangBegan：回應時補計一次
        let countHangNow = isHang && !current.hangReported
        for keyPath in [\MainLoopProbe.lifetime, \MainLoopProbe.window] {
            self[keyPath: keyPath].latency.record(latency)
            if latency > thresholds.lag { self[keyPath: keyPath].lagCount += 1 }
            if countHangNow { self[keyPath: keyPath].hangCount += 1 }
            self[keyPath: keyPath].longestStall = max(self[keyPath: keyPath].longestStall, latency)
        }
        return current.hangReported || isHang ? [.hangEnded(stall: latency)] : []
    }

    /// 系統睡眠或計時器重啟時丟掉在途探針，避免把睡眠時間算成卡住。
    public mutating func discardPending() {
        pending = nil
    }

    /// 在途探針已等多久（nil ＝ 目前沒有在途探針）。
    public func pendingAge(now: Duration) -> Duration? {
        pending.map { now - $0.postedAt }
    }

    /// 取出區間摘要並重新開始計算。
    public mutating func takeWindow() -> Summary {
        let taken = window
        window = Summary()
        return taken
    }
}
