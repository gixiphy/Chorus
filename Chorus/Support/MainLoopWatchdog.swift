import ChorusCore
import Foundation
import Synchronization

/// 主執行緒回應監測。背景 queue 上的計時器每秒往主執行緒投一支探針，量
/// 「排進去到真的執行」的延遲；判讀邏輯在 ChorusCore 的 `MainLoopProbe`。
///
/// 計時器與判讀**都不在主執行緒上**——被觀察的那條執行緒卡住時，還得有人
/// 看得到、記得下來。卡住當下寫一行、恢復時寫一行總時間，每 10 分鐘一行區間
/// 摘要（含操作統計）。正式版也開著：基線與事後分析都從 chorus.log 取，
/// 成本是每秒一次 main queue 投遞。
///
/// 時鐘用 `SuspendingClock`：睡眠期間不前進，睡前投出、醒後才執行的探針
/// 不會被算成一次好幾小時的卡住。
final class MainLoopWatchdog: Sendable {
    static let shared = MainLoopWatchdog()

    struct Configuration: Sendable {
        var interval: Duration = .seconds(1)
        var thresholds = MainLoopProbe.Thresholds()
        var summaryInterval: Duration = .seconds(600)
        /// 在途操作超過這麼久寫一行（每次操作只寫一次）。
        var operationStallThreshold: Duration = .seconds(5)
    }

    struct Snapshot: Sendable {
        let lifetime: MainLoopProbe.Summary
        /// 目前在途探針已等多久；主執行緒正卡著時就看這個。
        let pendingAge: Duration?
        let running: Bool
    }

    private struct State {
        var probe: MainLoopProbe
        var timer: DispatchSourceTimer?
        var lastSummaryAt: Duration = .zero
    }

    let configuration: Configuration
    private let metrics: OperationMetrics
    private let log: ChorusLog?
    private let queue = DispatchQueue(label: "com.hermes.Chorus.watchdog", qos: .utility)
    private let origin = SuspendingClock.now
    private let state: Mutex<State>

    init(
        configuration: Configuration = Configuration(),
        metrics: OperationMetrics = .shared,
        log: ChorusLog? = ChorusLog(category: "health")
    ) {
        self.configuration = configuration
        self.metrics = metrics
        self.log = log
        state = Mutex(State(probe: MainLoopProbe(thresholds: configuration.thresholds)))
    }

    private var now: Duration { origin.duration(to: .now) }

    /// 重複呼叫無副作用。
    func start() {
        let now = now
        let interval = configuration.interval.millis / 1_000
        state.withLock { state in
            guard state.timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now() + interval,
                repeating: interval,
                leeway: .milliseconds(max(1, Int(interval * 100)))
            )
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            state.timer = timer
            state.lastSummaryAt = now
        }
    }

    func stop() {
        state.withLock { state in
            state.timer?.cancel()
            state.timer = nil
            state.probe.discardPending()
        }
    }

    func snapshot() -> Snapshot {
        let now = now
        return state.withLock { state in
            Snapshot(
                lifetime: state.probe.lifetime,
                pendingAge: state.probe.pendingAge(now: now),
                running: state.timer != nil
            )
        }
    }

    /// 把上次摘要之後的區間寫出去（結束前呼叫，最後那段不會丟）。
    ///
    /// 在主執行緒上呼叫時，正卡著的那支探針還沒回來、不在直方圖裡——
    /// 另外帶上它已等多久，否則「卡住 1 次、最長 3 ms」會對不起來。
    func logWindowSummary(label: String) {
        let now = now
        let (summary, pendingAge) = state.withLock { state in
            (state.probe.takeWindow(), state.probe.pendingAge(now: now))
        }
        logSummary(summary, label: label, pendingAge: pendingAge)
    }

    // MARK: - 計時器（queue 上執行）

    private func tick() {
        let now = now
        let summaryInterval = configuration.summaryInterval
        let (probe, events, summary) = state.withLock {
            state -> (UInt64?, [MainLoopProbe.Event], MainLoopProbe.Summary?) in
            let result = state.probe.tick(now: now)
            var summary: MainLoopProbe.Summary?
            if now - state.lastSummaryAt >= summaryInterval {
                state.lastSummaryAt = now
                summary = state.probe.takeWindow()
            }
            return (result.probe, result.events, summary)
        }
        if let probe {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let answeredAt = self.now
                let events = self.state.withLock { $0.probe.answer(probe: probe, now: answeredAt) }
                // 寫檔留給背景 queue，探針本身在主執行緒上只做一次加鎖
                if !events.isEmpty {
                    self.queue.async { self.report(events) }
                }
            }
        }
        report(events)
        for stall in metrics.collectNewStalls(threshold: configuration.operationStallThreshold) {
            log?.notice("操作進行中已 \(OperationMetrics.format(stall.age))：\(stall.name)")
        }
        if let summary {
            let minutes = Int((summaryInterval.millis / 60_000).rounded())
            logSummary(summary, label: "近 \(minutes) 分鐘", pendingAge: nil)
        }
    }

    private func report(_ events: [MainLoopProbe.Event]) {
        for event in events {
            switch event {
            case let .hangBegan(pendingFor):
                log?.error("主執行緒無回應已 \(OperationMetrics.format(pendingFor))")
            case let .hangEnded(stall):
                log?.notice("主執行緒恢復回應，這次停頓 \(OperationMetrics.format(stall))")
            }
        }
    }

    private func logSummary(_ summary: MainLoopProbe.Summary, label: String, pendingAge: Duration?) {
        let stalledNow = pendingAge.flatMap { $0 > configuration.thresholds.lag ? $0 : nil }
        guard let log, summary.latency.count > 0 || stalledNow != nil else { return }
        let latency = summary.latency
        func percentile(_ fraction: Double) -> String {
            latency.percentile(fraction).map { "\(Int($0.rounded())) ms" } ?? "-"
        }
        var line = "主迴圈（\(label)）：樣本 \(latency.count)、P50 \(percentile(0.5))、"
            + "P95 \(percentile(0.95))、P99 \(percentile(0.99))、"
            + "最長 \(OperationMetrics.format(summary.longestStall))、"
            + "延遲 \(summary.lagCount) 次、卡住 \(summary.hangCount) 次"
            + (stalledNow.map { "、目前這支探針已等 \(OperationMetrics.format($0))" } ?? "")

        let snapshot = metrics.snapshot()
        let operations = snapshot.operations
            .filter { $0.value.started > 0 }
            .sorted { $0.key < $1.key }
            .prefix(16)
            .map { name, stats in
                let p95 = stats.latency.percentile(0.95).map { "\(Int($0.rounded())) ms" } ?? "-"
                let failures = stats.completed - (stats.outcomes[.success] ?? 0)
                return "\(name) \(stats.completed) 次 P95 \(p95) 最長 \(Int(stats.latency.maxMillis.rounded())) ms"
                    + (failures > 0 ? " 失敗 \(failures)" : "")
                    + (stats.inFlight > 0 ? " 在途 \(stats.inFlight)" : "")
            }
        if !operations.isEmpty {
            line += "｜操作累計：" + operations.joined(separator: "；")
        }
        let gauges = snapshot.gauges
            .filter { $0.value.highWater > 0 }
            .sorted { $0.key < $1.key }
            .map { "\($0.key) 現 \($0.value.current) 高 \($0.value.highWater)" }
        if !gauges.isEmpty {
            line += "｜佇列：" + gauges.joined(separator: "；")
        }
        log.notice(line)
    }
}
