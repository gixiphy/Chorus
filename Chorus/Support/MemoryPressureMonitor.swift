import ChorusCore
import Foundation
import Synchronization

/// 記憶體壓力監測與降級（Batch F）。
///
/// 8 GB 的機器上 swap 常駐好幾 GB 是常態，Chorus 不該在這種時候再加碼。
/// **只在 critical 時降級**：暫停自動雲端備份、不啟動會吃上百 MB 的 AI CLI；
/// 使用者手動的備份、音訊與顯示器控制照常。warning 只記錄與顯示——常駐 warning
/// 的機器上若也暫停，自動備份就永遠跑不到。
///
/// 升級立刻生效，降級要等恢復期（`MemoryPressureGovernor`）。狀態寫進紀錄與
/// `/v1/health`，事後對得上「那時候整台機器正在換頁」。
final class MemoryPressureMonitor: Sendable {
    typealias Level = MemoryPressureGovernor.Level

    static let shared = MemoryPressureMonitor()

    private struct State {
        var governor: MemoryPressureGovernor
        var source: DispatchSourceMemoryPressure?
        var ticker: DispatchSourceTimer?
    }

    private let state: Mutex<State>
    private let queue = DispatchQueue(label: "com.hermes.Chorus.memory-pressure", qos: .utility)
    private let origin = ContinuousClock.now
    private let tickInterval: Duration
    private let log: ChorusLog?

    init(
        recovery: Duration = .seconds(30),
        tickInterval: Duration = .seconds(5),
        log: ChorusLog? = ChorusLog(category: "health")
    ) {
        state = Mutex(State(governor: MemoryPressureGovernor(recovery: recovery)))
        self.tickInterval = tickInterval
        self.log = log
    }

    /// 呼叫端依據的等級（含恢復期）。
    var level: Level { state.withLock { $0.governor.effective } }

    /// critical：暫停自動背景工作、不啟動大型子行程。
    var blocksHeavyWork: Bool { level == .critical }

    /// 開始接收系統事件。重複呼叫無副作用。
    func start() {
        state.withLock { state in
            guard state.source == nil else { return }
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: queue)
            source.setEventHandler { [weak self] in
                guard let self, let event = self.state.withLock({ $0.source?.data }) else { return }
                let level: Level = event.contains(.critical) ? .critical : event.contains(.warning) ? .warning : .normal
                self.report(level)
            }
            source.resume()
            state.source = source
        }
    }

    /// 送進一個等級（系統事件，或 DEBUG 的模擬）。
    func report(_ level: Level) {
        let now = origin.duration(to: .now)
        let (changed, needsTicks) = state.withLock { state in
            (state.governor.report(level, now: now), state.governor.needsTicks)
        }
        if let changed { logTransition(to: changed) }
        if needsTicks { ensureTicker() }
    }

    static func name(_ level: Level) -> String {
        switch level {
        case .normal: "normal"
        case .warning: "warning"
        case .critical: "critical"
        }
    }

    private func ensureTicker() {
        let seconds = tickInterval.millis / 1_000
        state.withLock { state in
            guard state.ticker == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + seconds, repeating: seconds)
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            state.ticker = timer
        }
    }

    private func tick() {
        let now = origin.duration(to: .now)
        let changed = state.withLock { state -> Level? in
            let changed = state.governor.tick(now: now)
            if !state.governor.needsTicks {
                state.ticker?.cancel()
                state.ticker = nil
            }
            return changed
        }
        if let changed { logTransition(to: changed) }
    }

    private func logTransition(to level: Level) {
        let effect = switch level {
        case .critical: "暫停自動備份，不啟動 AI 引擎"
        case .warning: "只記錄，不降級"
        case .normal: "恢復正常"
        }
        log?.notice("記憶體壓力 → \(Self.name(level))（\(effect)）")
    }
}
