import Synchronization

/// 測試用、手動推進的時鐘。期限、逾時與退避的測試靠它控制時間，
/// 不用真的 sleep 撐時間，也不會因為 CI 機器慢而時好時壞。
public final class ManualClock: Clock, Sendable {
    public struct Instant: InstantProtocol, Sendable {
        public var offset: Duration

        public init(offset: Duration) {
            self.offset = offset
        }

        public func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        public func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        public static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var sleepers: [UInt64: Sleeper] = [:]
        var nextID: UInt64 = 0
        /// 取消比註冊先到的 sleeper。
        var cancelledEarly: Set<UInt64> = []
    }

    private let state = Mutex(State())

    public init() {}

    public var now: Instant { state.withLock { $0.now } }

    public var minimumResolution: Duration { .zero }

    /// 正在等待的 sleep 數。測試用它確認對方已經睡下，再推進時間。
    public var sleeperCount: Int { state.withLock { $0.sleepers.count } }

    public func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        try Task.checkCancellation()
        let id = state.withLock { state in
            state.nextID += 1
            return state.nextID
        }
        // onCancel 在 operation 返回後不會再執行；這裡清掉它可能留下的標記
        defer { state.withLock { _ = $0.cancelledEarly.remove(id) } }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case wait, resume, cancel }
                let action: Action = state.withLock { state in
                    if state.cancelledEarly.remove(id) != nil { return .cancel }
                    if deadline <= state.now { return .resume }
                    state.sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    return .wait
                }
                switch action {
                case .wait: break
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let sleeper: Sleeper? = state.withLock { state in
                if let sleeper = state.sleepers.removeValue(forKey: id) { return sleeper }
                state.cancelledEarly.insert(id)
                return nil
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    /// 推進時間，喚醒期限已到的 sleep（依期限先後）。
    public func advance(by duration: Duration) {
        let due: [Sleeper] = state.withLock { state in
            state.now = state.now.advanced(by: duration)
            let now = state.now
            let ready = state.sleepers
                .filter { $0.value.deadline <= now }
                .sorted { $0.value.deadline < $1.value.deadline }
            for (id, _) in ready {
                state.sleepers.removeValue(forKey: id)
            }
            return ready.map(\.value)
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }
}
