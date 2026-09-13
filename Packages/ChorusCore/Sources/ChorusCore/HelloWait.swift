import Synchronization

/// 等對方的 hello，有期限。
///
/// `AsyncStream` 的 `next()` 沒辦法從別的 task 打斷，所以逾時的做法是**關掉連線**：
/// 底層 stream 隨之結束，`next()` 才會返回。呼叫端拿到 `.timedOut` 時連線已經關了。
///
/// 我方的 hello 在 `sendOwnHello` 裡送，與等待共用同一個期限——送出本身卡住
/// （對方不讀）時，關掉連線也會讓那次送出失敗返回。
public enum HelloWait {
    public enum Outcome: Sendable, Equatable {
        case hello(Hello)
        /// 第一筆不是 hello（協定錯誤）。
        case unexpected
        /// 還沒收到任何東西連線就關了。
        case closed
        case timedOut
    }

    public static let defaultTimeout: Duration = .seconds(5)

    public static func awaitHello<C: Clock>(
        from iterator: inout AsyncStream<Envelope>.Iterator,
        timeout: Duration = defaultTimeout,
        clock: C,
        isolation: isolated (any Actor)? = #isolation,
        close: @escaping @Sendable () -> Void,
        sendOwnHello: () async -> Void = {}
    ) async -> Outcome where C.Duration == Duration {
        let expired = ExpiryFlag()
        let watchdog = Task {
            do {
                try await clock.sleep(for: timeout)
            } catch {
                return
            }
            expired.set()
            close()
        }
        defer { watchdog.cancel() }

        await sendOwnHello()
        let first = await iterator.next(isolation: isolation)
        if expired.isSet { return .timedOut }
        guard let first else { return .closed }
        guard case let .hello(hello) = first.msg else { return .unexpected }
        return .hello(hello)
    }
}

private final class ExpiryFlag: Sendable {
    private let value = Atomic(false)

    func set() {
        value.store(true, ordering: .sequentiallyConsistent)
    }

    var isSet: Bool {
        value.load(ordering: .sequentiallyConsistent)
    }
}
