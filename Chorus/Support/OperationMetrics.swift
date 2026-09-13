import ChorusCore
import Foundation
import Synchronization

/// 操作耗時、在途數與佇列深度。帳本是 ChorusCore 的 `OperationLedger`，
/// 這裡只加鎖、時鐘與「慢操作」紀錄。
///
/// 時鐘用 `SuspendingClock`：系統睡眠期間不前進，睡一晚醒來不會被記成
/// 一次八小時的慢操作。
final class OperationMetrics: Sendable {
    static let shared = OperationMetrics()

    struct Token: Sendable {
        fileprivate let id: UInt64
    }

    struct Snapshot: Sendable {
        let operations: [String: OperationStats]
        let gauges: [String: GaugeStats]
        let oldestInFlight: [String: Duration]
        let untrackedBegins: Int
    }

    /// 單次超過就寫一行紀錄；同一種操作 60 秒內只寫一次，持續出錯不會灌爆紀錄檔。
    let slowThreshold: Duration
    private static let slowLogInterval: Duration = .seconds(60)

    private let origin = SuspendingClock.now
    private let ledger = Mutex(OperationLedger())
    private let lastSlowLog = Mutex([String: Duration]())
    private let log: ChorusLog?

    init(slowThreshold: Duration = .seconds(1), log: ChorusLog? = ChorusLog(category: "health")) {
        self.slowThreshold = slowThreshold
        self.log = log
    }

    /// 單調時間（不含睡眠）。
    var now: Duration { origin.duration(to: .now) }

    func begin(_ name: String) -> Token {
        let now = now
        return Token(id: ledger.withLock { $0.begin(name, now: now) })
    }

    func end(_ token: Token, _ outcome: OperationOutcome = .success) {
        let now = now
        guard let finished = ledger.withLock({ $0.end(token.id, outcome: outcome, now: now) }),
              finished.elapsed >= slowThreshold
        else { return }
        let shouldLog = lastSlowLog.withLock { last in
            if let previous = last[finished.name], now - previous < Self.slowLogInterval { return false }
            last[finished.name] = now
            return true
        }
        guard shouldLog else { return }
        log?.notice("慢操作 \(finished.name) 耗時 \(Self.format(finished.elapsed))（\(outcome.rawValue)）")
    }

    func measure<T>(_ name: String, _ body: () throws -> T) rethrows -> T {
        let token = begin(name)
        do {
            let value = try body()
            end(token)
            return value
        } catch {
            end(token, .failure)
            throw error
        }
    }

    func measureAsync<T>(
        _ name: String,
        isolation: isolated (any Actor)? = #isolation,
        _ body: () async throws -> T
    ) async rethrows -> T {
        let token = begin(name)
        do {
            let value = try await body()
            end(token)
            return value
        } catch {
            end(token, error is CancellationError ? .cancelled : .failure)
            throw error
        }
    }

    func adjustGauge(_ name: String, by delta: Int) {
        ledger.withLock { $0.adjustGauge(name, by: delta) }
    }

    /// 在途超過門檻、之前沒報過的操作（watchdog 每拍來收）。
    func collectNewStalls(threshold: Duration) -> [OperationLedger.Stall] {
        let now = now
        return ledger.withLock { $0.collectNewStalls(now: now, threshold: threshold) }
    }

    func snapshot() -> Snapshot {
        let now = now
        return ledger.withLock { ledger in
            Snapshot(
                operations: ledger.operations,
                gauges: ledger.gauges,
                oldestInFlight: ledger.oldestInFlightAge(now: now),
                untrackedBegins: ledger.untrackedBegins
            )
        }
    }

    /// `12 ms`、`4.0 s`。
    static func format(_ duration: Duration) -> String {
        let millis = duration.millis
        return millis < 1_000 ? "\(Int(millis.rounded())) ms" : String(format: "%.1f s", millis / 1_000)
    }
}
