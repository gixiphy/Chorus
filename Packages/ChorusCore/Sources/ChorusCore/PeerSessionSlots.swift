/// 重撥退避：1、2、4、8、16、30 秒封頂，每次 ±20% jitter。
///
/// jitter 讓兩台同時醒來、同時重開的機器不會永遠在同一拍撞在一起。亂數由呼叫端
/// 注入（0..<1），測試才能固定結果。
public struct RedialBackoff: Sendable, Equatable {
    public static let steps: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(8), .seconds(16), .seconds(30)]
    public static let jitter = 0.2

    public private(set) var attempt = 0

    public init() {}

    public mutating func next(random: Double) -> Duration {
        let base = Self.steps[min(attempt, Self.steps.count - 1)]
        attempt += 1
        let clamped = min(max(random, 0), 1)
        let factor = 1 + Self.jitter * (2 * clamped - 1)
        return .milliseconds(Int64((base.millis * factor).rounded()))
    }

    public mutating func reset() {
        attempt = 0
    }
}

/// 同步連線的生命週期，每個 peer 一個 slot（純邏輯；時間與亂數由呼叫端注入）。
///
/// 規則：
/// - **同一個 peer 同時最多一件工作**：撥號中、等 hello、已連線、退避中都佔著 slot，
///   探索回呼再怎麼密也不會多撥一條。
/// - **每件工作帶 generation**：睡醒、停止、被新連線取代之後，舊工作晚到的結果一律
///   作廢，不會把新連線的狀態清掉。
/// - **任何前期失敗都走同一條路**：撥號失敗、hello 逾時、第一筆不是 hello，都進退避；
///   不會停在「連線中」也不會無退避重撥。
/// - **session 要撐過 `stableSession` 才算恢復**：hello 一過就被關掉的連線（例如對方
///   把我們的訊息當協定錯誤）繼續拉長退避，不會每秒重來一次。
/// - 只有 peerID 較小的一方撥號（沿用既有去重規則）；另一方只記狀態、不重撥。
public struct PeerSessionSlots: Sendable {
    public enum Phase: Sendable, Equatable {
        case idle
        case dialing
        case awaitingHello
        case connected
        case backoff(until: Duration)
    }

    public struct Slot: Sendable, Equatable {
        public fileprivate(set) var phase: Phase = .idle
        public fileprivate(set) var generation: UInt64 = 0
        public fileprivate(set) var backoff = RedialBackoff()
        /// 上一次撥號用的端點；探索到**不同的**端點時可以提前結束退避。
        public fileprivate(set) var lastEndpoint: String?
        public fileprivate(set) var connectedAt: Duration?
    }

    /// 連線維持這麼久才把退避歸零。
    public static let stableSession: Duration = .seconds(10)

    public enum DialDecision: Sendable, Equatable {
        case start(generation: UInt64)
        case ignore
    }

    public let localPeerID: String
    public private(set) var isRunning = false
    public private(set) var slots: [String: Slot] = [:]
    private var lastGeneration: UInt64 = 0

    public init(localPeerID: String) {
        self.localPeerID = localPeerID
    }

    public func isDialer(for peer: String) -> Bool {
        localPeerID < peer
    }

    public func phase(of peer: String) -> Phase {
        slots[peer]?.phase ?? .idle
    }

    public func generation(of peer: String) -> UInt64? {
        slots[peer]?.generation
    }

    public mutating func start() {
        isRunning = true
    }

    /// 停止：所有工作作廢，之後不再撥號。回傳原本有工作的 peer（呼叫端要收掉的）。
    @discardableResult
    public mutating func stop() -> [String] {
        isRunning = false
        let active = slots.filter { $0.value.phase != .idle }.keys.sorted()
        for peer in Array(slots.keys) {
            invalidate(peer)
            slots[peer]?.backoff.reset()
        }
        return active
    }

    /// 睡醒或網路整個重來：所有工作作廢、退避歸零。回傳要立刻撥號的 peer。
    public mutating func reset(peers: [String]) -> [String] {
        for peer in peers where slots[peer] == nil {
            slots[peer] = Slot()
        }
        for peer in Array(slots.keys) {
            invalidate(peer)
            slots[peer]?.backoff.reset()
        }
        guard isRunning else { return [] }
        return peers.filter(isDialer(for:)).sorted()
    }

    /// 取消配對：slot 整個拿掉，舊工作的結果都會作廢。
    public mutating func remove(_ peer: String) {
        slots[peer] = nil
    }

    /// 探索、配對變更時呼叫。
    public mutating func requestDial(_ peer: String, endpoint: String?, now: Duration) -> DialDecision {
        guard isRunning, isDialer(for: peer) else { return .ignore }
        let slot = slots[peer] ?? Slot()
        switch slot.phase {
        case .idle:
            break
        case let .backoff(until):
            let freshEndpoint = endpoint != nil && endpoint != slot.lastEndpoint
            guard now >= until || freshEndpoint else { return .ignore }
        case .dialing, .awaitingHello, .connected:
            return .ignore
        }
        return beginDial(peer, endpoint: endpoint)
    }

    /// 退避計時到期（帶著排程時的 generation）。
    public mutating func backoffElapsed(_ peer: String, generation: UInt64) -> DialDecision {
        guard isRunning, let slot = slots[peer], slot.generation == generation,
              case .backoff = slot.phase
        else { return .ignore }
        return beginDial(peer, endpoint: slot.lastEndpoint)
    }

    /// 底層連線 ready（TLS 完成），開始等 hello。
    public mutating func connectReady(_ peer: String, generation: UInt64) -> Bool {
        guard isCurrent(peer, generation), slots[peer]?.phase == .dialing else { return false }
        slots[peer]?.phase = .awaitingHello
        return true
    }

    /// 撥號或 hello 階段失敗。回傳下次重撥延遲；nil ＝ 舊工作、已停止或不歸我撥。
    public mutating func attemptFailed(_ peer: String, generation: UInt64, now: Duration, random: Double) -> Duration? {
        guard isCurrent(peer, generation) else { return nil }
        switch slots[peer]?.phase {
        case .dialing, .awaitingHello:
            break
        default:
            return nil
        }
        return scheduleBackoff(peer, now: now, random: random)
    }

    /// hello 驗證通過。`generation` 是撥號方自己那件工作的；接受方（對方撥進來）傳 nil。
    /// 回傳這個 session 的 generation，nil ＝ 撥號結果已作廢。
    public mutating func sessionEstablished(_ peer: String, generation: UInt64?, now: Duration) -> UInt64? {
        if let generation {
            guard isCurrent(peer, generation), slots[peer]?.phase == .awaitingHello else { return nil }
            slots[peer]?.phase = .connected
            slots[peer]?.connectedAt = now
            return generation
        }
        // 撥進來的連線：取代這個 peer 手上的任何工作（撥號中的結果隨之作廢）
        if slots[peer] == nil { slots[peer] = Slot() }
        let fresh = nextGeneration()
        slots[peer]?.generation = fresh
        slots[peer]?.phase = .connected
        slots[peer]?.connectedAt = now
        return fresh
    }

    /// 已建立的 session 結束。回傳重撥延遲（撥號方且仍在執行時）。
    public mutating func sessionClosed(_ peer: String, generation: UInt64, now: Duration, random: Double) -> Duration? {
        guard isCurrent(peer, generation), slots[peer]?.phase == .connected else { return nil }
        if let connectedAt = slots[peer]?.connectedAt, now - connectedAt >= Self.stableSession {
            slots[peer]?.backoff.reset()
        }
        slots[peer]?.connectedAt = nil
        return scheduleBackoff(peer, now: now, random: random)
    }

    // MARK: - 內部

    private func isCurrent(_ peer: String, _ generation: UInt64) -> Bool {
        slots[peer]?.generation == generation
    }

    private mutating func nextGeneration() -> UInt64 {
        lastGeneration += 1
        return lastGeneration
    }

    private mutating func beginDial(_ peer: String, endpoint: String?) -> DialDecision {
        if slots[peer] == nil { slots[peer] = Slot() }
        let generation = nextGeneration()
        slots[peer]?.generation = generation
        slots[peer]?.phase = .dialing
        slots[peer]?.lastEndpoint = endpoint
        return .start(generation: generation)
    }

    private mutating func scheduleBackoff(_ peer: String, now: Duration, random: Double) -> Duration? {
        guard isRunning, isDialer(for: peer) else {
            slots[peer]?.phase = .idle
            return nil
        }
        var backoff = slots[peer]?.backoff ?? RedialBackoff()
        let delay = backoff.next(random: random)
        slots[peer]?.backoff = backoff
        slots[peer]?.phase = .backoff(until: now + delay)
        return delay
    }

    private mutating func invalidate(_ peer: String) {
        let generation = nextGeneration()
        slots[peer]?.generation = generation
        slots[peer]?.phase = .idle
    }
}
