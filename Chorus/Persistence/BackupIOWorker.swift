import Foundation
import Synchronization

/// 備份檔案 I/O 的專用序列 worker。
///
/// iCloud Drive 的檔案呼叫是**同步、而且沒辦法取消**的：CloudDocs 暫停或網路
/// 卡住時，一次 write 可以卡上不定時間。Swift 的取消是合作式的，打斷不了它。所以：
/// - **呼叫端有期限**：到期先回 `.timedOut`，I/O 自己繼續跑完，晚到的結果丟掉。
/// - **卡住的那件事仍佔著唯一的 worker**：不另開執行緒追加；它超過期限還沒回來時，
///   新工作直接回 `.busy`。佇列也有上限——卡一個小時不會堆出一小時份的工作。
final class BackupIOWorker: Sendable {
    enum Outcome<Value: Sendable>: Sendable {
        case completed(Result<Value, any Error>)
        /// 期限到了還沒做完。工作本身可能還在跑，之後才會寫進磁碟。
        case timedOut
        /// 前一件工作卡住或排隊已滿，這件沒有排進去。
        case busy
    }

    let files: CloudBackupFiles
    let maxQueued: Int

    private struct State {
        var queued = 0
        var inFlightStartedAt: Duration?
        var inFlightDeadline: Duration = .zero
    }

    private let queue = DispatchQueue(label: "com.hermes.Chorus.backup-io", qos: .utility)
    private let state = Mutex(State())
    private let origin = SuspendingClock.now

    init(files: CloudBackupFiles, maxQueued: Int = 8) {
        self.files = files
        self.maxQueued = max(1, maxQueued)
    }

    private var now: Duration { origin.duration(to: .now) }

    /// 沒有工作在跑、也沒有排隊。
    var isIdle: Bool {
        state.withLock { $0.queued == 0 && $0.inFlightStartedAt == nil }
    }

    func run<Value: Sendable>(
        deadline: Duration,
        _ work: @escaping @Sendable (CloudBackupFiles) throws -> Value
    ) async -> Outcome<Value> {
        let submittedAt = now
        let admitted = state.withLock { state -> Bool in
            if let started = state.inFlightStartedAt, submittedAt - started > state.inFlightDeadline {
                return false
            }
            guard state.queued < maxQueued else { return false }
            state.queued += 1
            return true
        }
        guard admitted else { return .busy }
        OperationMetrics.shared.adjustGauge("cloud.queue", by: 1)

        let files = files
        return await withCheckedContinuation { continuation in
            let gate = OutcomeGate(continuation)
            queue.async { [self] in
                let startedAt = now
                state.withLock { state in
                    state.queued -= 1
                    state.inFlightStartedAt = startedAt
                    state.inFlightDeadline = deadline
                }
                OperationMetrics.shared.adjustGauge("cloud.queue", by: -1)
                let result = Result { try work(files) }
                state.withLock { $0.inFlightStartedAt = nil }
                gate.resume(.completed(result))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline.millis / 1_000) {
                gate.resume(.timedOut)
            }
        }
    }
}

/// 完成與逾時兩條路只有先到的那條會 resume。
private final class OutcomeGate<Value: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<BackupIOWorker.Outcome<Value>, Never>?>

    init(_ continuation: CheckedContinuation<BackupIOWorker.Outcome<Value>, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ outcome: BackupIOWorker.Outcome<Value>) {
        let taken = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        taken?.resume(returning: outcome)
    }
}
