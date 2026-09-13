import ChorusCore
import Foundation

/// 可控的故障注入：讓「iCloud Drive 卡住」「對端不回 hello」這類事故能在測試裡
/// 穩定重現，前後版本拿同一個條件量。
///
/// 只有 DEBUG build 有入口（啟動參數 `--fault`、測試掛鉤的 `fault` 動作）；
/// 正式版沒有任何路徑會設它，每個注入點只剩一次查表。預設用 `.shared`，
/// 單元測試各自建一個——Swift Testing 平行跑，共用一份會互相干擾。
final class FaultRegistry: @unchecked Sendable {
    static let shared = FaultRegistry()

    struct InjectedFault: LocalizedError, Equatable {
        let point: FaultPoint
        var errorDescription: String? { "注入的故障：\(point.rawValue)" }
    }

    /// `hang` 的安全上限：忘了解除時，測試行程不會永遠卡著。
    let hangLimit: Duration

    /// 保護 `faults`；`hang`／`delay` 也在它上面等「設定改變」。
    private let condition = NSCondition()
    private var faults: [FaultPoint: FaultBehavior] = [:]
    private let log = ChorusLog(category: "fault")

    init(hangLimit: Duration = .seconds(120)) {
        self.hangLimit = hangLimit
    }

    func set(_ point: FaultPoint, _ behavior: FaultBehavior?) {
        condition.withLock {
            faults[point] = behavior
            condition.broadcast()
        }
    }

    /// 套用一條 `FaultSpec` 文字。解析失敗寫紀錄並回 false。
    @discardableResult
    func apply(spec: String) -> Bool {
        do {
            let (point, behavior) = try FaultSpec.parse(spec)
            set(point, behavior)
            log.notice(behavior.map { "注入故障 \(point.rawValue)：\($0)" } ?? "解除故障 \(point.rawValue)")
            return true
        } catch {
            log.error("無法解析故障規格「\(spec)」：\(error)")
            return false
        }
    }

    #if DEBUG
    /// 啟動參數裡的每一個 `--fault <spec>`。
    func configure(arguments: [String]) {
        for (index, argument) in arguments.enumerated() where argument == "--fault" && index + 1 < arguments.count {
            apply(spec: arguments[index + 1])
        }
    }
    #endif

    func behavior(for point: FaultPoint) -> FaultBehavior? {
        condition.withLock { faults[point] }
    }

    var active: [FaultPoint: FaultBehavior] {
        condition.withLock { faults }
    }

    func isWithholding(_ point: FaultPoint) -> Bool {
        behavior(for: point) == .withhold
    }

    /// 同步呼叫點：**阻塞呼叫端執行緒**——要重現的正是這種故障。
    /// `delay`／`hang` 在期限到或該位置的設定被改掉時結束。
    func injectBlocking(_ point: FaultPoint) throws(InjectedFault) {
        condition.lock()
        defer { condition.unlock() }
        guard let behavior = faults[point] else { return }
        switch behavior {
        case .fail:
            throw InjectedFault(point: point)
        case .withhold:
            return
        case let .delay(duration):
            waitLocked(point, while: behavior, upTo: duration)
        case .hang:
            waitLocked(point, while: behavior, upTo: hangLimit)
        }
    }

    /// 非同步呼叫點：用 Task.sleep 等，可被取消。
    func inject(_ point: FaultPoint) async throws {
        guard let behavior = behavior(for: point) else { return }
        switch behavior {
        case .fail:
            throw InjectedFault(point: point)
        case .withhold:
            return
        case let .delay(duration):
            try await Task.sleep(for: duration)
        case .hang:
            let deadline = ContinuousClock.now + hangLimit
            while self.behavior(for: point) == .hang, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    /// 持鎖呼叫。
    private func waitLocked(_ point: FaultPoint, while behavior: FaultBehavior, upTo duration: Duration) {
        let deadline = Date(timeIntervalSinceNow: duration.millis / 1_000)
        while faults[point] == behavior, Date() < deadline {
            _ = condition.wait(until: deadline)
        }
    }
}
