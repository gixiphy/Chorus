import Darwin
import Foundation

/// App 啟動各步驟的耗時（Batch F）：選單出來之前主執行緒花在哪裡。
///
/// AppState 的 init 裡不能用 closure 包住屬性指定（self 還沒初始化完），所以用
/// 「打點」：每一步之後 `mark`，記下與上一個點之間的時間。結束時寫一行紀錄，
/// 每一步也進操作計量（`startup.<步驟>`），`/v1/health` 看得到。
@MainActor
struct StartupTimeline {
    private let metrics: OperationMetrics
    private let started: Duration
    private var last: Duration
    private var steps: [(name: String, elapsed: Duration)] = []

    init(metrics: OperationMetrics = .shared) {
        self.metrics = metrics
        started = metrics.now
        last = started
    }

    /// 記下從上一個點到現在這一步花的時間。
    mutating func mark(_ name: String) {
        let now = metrics.now
        let elapsed = now - last
        last = now
        steps.append((name, elapsed))
        metrics.record("startup.\(name)", elapsed: elapsed)
    }

    /// 寫一行：總耗時、行程啟動到這裡的時間，以及超過 `threshold` 的步驟（慢的在前）。
    func finish(log: ChorusLog = .app, threshold: Duration = .milliseconds(5)) {
        let total = metrics.now - started
        let notable = steps
            .filter { $0.elapsed >= threshold }
            .sorted { $0.elapsed > $1.elapsed }
            .map { "\($0.name) \(OperationMetrics.format($0.elapsed))" }
        let sinceLaunch = Self.timeSinceProcessStart().map { "，行程啟動至今 \(OperationMetrics.format($0))" } ?? ""
        log.notice(
            "啟動耗時 \(OperationMetrics.format(total))\(sinceLaunch)："
                + (notable.isEmpty ? "沒有超過 \(OperationMetrics.format(threshold)) 的步驟" : notable.joined(separator: "、"))
        )
    }

    /// 核心記錄的行程啟動時間到現在（牆鐘；只用於啟動這種短區間）。
    static func timeSinceProcessStart() -> Duration? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        let seconds = Date().timeIntervalSince1970 - started
        guard seconds >= 0 else { return nil }
        return .milliseconds(Int64(seconds * 1_000))
    }
}
