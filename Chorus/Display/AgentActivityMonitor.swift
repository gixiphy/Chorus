import ChorusCore
import Foundation
import Observation

/// 「有 agent 在工作時才防睡眠」的活動偵測（M9-2）。
///
/// 兩層跡證，理由見 `AgentSessionSample`：
/// 1. **session log 有沒有在長**——認得的 agent 走 `AgentRegistry` 的根目錄表。
///    讀的是目錄列表與 mtime，**不開檔、不讀內容**，也不需要任何權限：
///    `~/.claude`、`~/.codex` 都不在 TCC 保護的目錄裡（Chorus 也沒有沙箱）。
/// 2. **有終端機的行程樹有沒有在燒 CPU**——涵蓋沒有全域 log 的 agent 與使用者
///    自訂的 CLI（`AgentProcessScanner`）。可在設定頁關掉。
///
/// 只在 Agent 模式啟用時輪詢。實測第一層約 50 ms、第二層 ≤ 10 ms，30 秒一次
/// 約是單核的 0.2%；兩層都丟到背景 utility 佇列，不佔 main actor。
/// 週期抓 30 秒是因為它只需要比「系統待機倒數」快——那是以分鐘計的。
@MainActor
@Observable
final class AgentActivityMonitor {
    /// 目前算「工作中」的 session，最近活動的排前面。
    private(set) var working: [AgentSessionSample] = []
    var isWorking: Bool { !working.isEmpty }

    /// 工作中的 session 是哪幾支 agent 的（選單說明用，去重、保持出現順序）。
    var engines: [String] {
        var seen = Set<String>()
        return working.compactMap { seen.insert($0.engine).inserted ? $0.engine : nil }
    }

    /// 「工作中／收工」翻面時通知控制器重新評估。中間的成員變動不通知——
    /// assertion 只看有沒有，多一個少一個不影響。
    @ObservationIgnored var onWorkingChanged: (() -> Void)?

    @ObservationIgnored private let sources: [ResolvedAgentLogSource]
    @ObservationIgnored private let processSampler: (any AgentProcessSampling)?
    @ObservationIgnored private let graceSeconds: Double
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var processState = AgentProcessActivityPlanner.State()
    @ObservationIgnored private var matcher = AgentProcessMatcher()
    @ObservationIgnored private var processDetectionEnabled = true

    /// 第一層掃描超過這個時間就寫一行 `.notice` 並點名最慢的根——
    /// 這是常駐成本，變慢了要看得到，不能只活在 `.debug` 裡。
    private static let slowLogScan: Duration = .milliseconds(250)

    init(
        sources: [ResolvedAgentLogSource] = AgentRegistry.resolvedLogSources(
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment
        ),
        processSampler: (any AgentProcessSampling)? = AgentProcessScanner(),
        graceSeconds: Double = AgentActivityPlanner.defaultGraceSeconds,
        pollInterval: Duration = .seconds(30),
        now: @escaping () -> Date = Date.init
    ) {
        self.sources = sources
        self.processSampler = processSampler
        self.graceSeconds = graceSeconds
        self.pollInterval = pollInterval
        self.now = now
    }

    /// 開始輪詢（重複呼叫無效果）。先掃一輪再進迴圈，
    /// 使用者選下 Agent 模式時不必等 15 秒才看到狀態。
    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    /// 停掉輪詢並清空狀態。**不觸發 `onWorkingChanged`**：叫停的兩處
    /// （切出 Agent 模式、App 收攤）本來就會接著重新評估，
    /// 從這裡回呼只會多一次可有可無的重入。
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        working = []
        processState = AgentProcessActivityPlanner.State()
    }

    /// 設定頁改了第二層的開關或自訂行程名。
    ///
    /// 關掉時把行程狀態清乾淨：留著的話重開之後第一輪會拿舊的累計 CPU
    /// 去比新的，算出一個假的大差值。
    func configureProcessDetection(enabled: Bool, customProcessNames: [String]) {
        let next = AgentProcessMatcher(customProcessNames: customProcessNames)
        let changed = enabled != processDetectionEnabled || next != matcher
        processDetectionEnabled = enabled
        matcher = next
        if !enabled { processState = AgentProcessActivityPlanner.State() }
        // 輪詢中才立刻補一輪：沒在輪詢時 `working` 本來就是空的。
        guard changed, pollTask != nil else { return }
        Task { await refresh() }
    }

    /// 掃一輪並套用。測試直接呼叫這支，不必等輪詢。
    func refresh() async {
        let sampler = processDetectionEnabled ? processSampler : nil
        let matcher = matcher
        // 兩層互不相干：目錄 IO 與 syscall 同時跑，一輪的長度是慢的那一半。
        async let logScan = Self.scanLogs(sources)
        async let processScan = Self.scanProcesses(sampler, matcher: matcher)
        let (logs, processes) = await (logScan, processScan)

        var processSamples: [AgentSessionSample] = []
        if let snapshot = processes.snapshot {
            let stepped = AgentProcessActivityPlanner.step(processState, snapshot: snapshot)
            processState = stepped.state
            processSamples = stepped.samples
        }

        OperationMetrics.shared.record("agent.scanLogs", elapsed: logs.elapsed)
        if processes.snapshot != nil {
            OperationMetrics.shared.record("agent.scanProcesses", elapsed: processes.elapsed)
        }
        ChorusLog.display.debug(
            "agent scan: logs \(logs.samples.count) files/\(OperationMetrics.format(logs.elapsed))"
                + " (\(logs.rootCount) roots), procs \(processSamples.count) trees/"
                + "\(OperationMetrics.format(processes.elapsed))"
                + (processes.snapshot.map { Self.describeTrees($0) } ?? "")
        )
        if logs.elapsed >= Self.slowLogScan, let slowest = logs.slowest {
            ChorusLog.display.notice(
                "Agent log 掃描耗時 \(OperationMetrics.format(logs.elapsed))，"
                    + "最慢的根是 \(slowest.engine)（\(OperationMetrics.format(slowest.elapsed))）"
            )
        }

        apply(
            AgentActivityMerger.merge(
                logSamples: logs.samples,
                processSamples: processSamples,
                now: now(),
                graceSeconds: graceSeconds
            )
        )
    }

    private func apply(_ samples: [AgentSessionSample]) {
        let next = AgentActivityPlanner.workingSessions(samples, now: now(), graceSeconds: graceSeconds)
        let wasWorking = isWorking
        working = next
        guard wasWorking != isWorking else { return }
        if isWorking {
            ChorusLog.display.info("Agent 活動：工作中 ← \(Self.describe(next))")
        } else {
            ChorusLog.display.info("Agent 活動：收工")
        }
        onWorkingChanged?()
    }

    // MARK: - 說明字串

    /// `Claude Code(log×2)、Cursor CLI(pid 4132)`——翻面那一行要看得出是誰、從哪一層來的。
    private static func describe(_ samples: [AgentSessionSample]) -> String {
        var order: [String] = []
        var logCounts: [String: Int] = [:]
        var pids: [String: [String]] = [:]
        for sample in samples {
            if !order.contains(sample.engine) { order.append(sample.engine) }
            if let pid = sample.id.dropPIDPrefix() {
                pids[sample.engine, default: []].append(pid)
            } else {
                logCounts[sample.engine, default: 0] += 1
            }
        }
        return order.map { engine in
            var parts: [String] = []
            if let count = logCounts[engine] { parts.append("log×\(count)") }
            parts.append(contentsOf: (pids[engine] ?? []).map { "pid \($0)" })
            return "\(engine)(\(parts.joined(separator: "、")))"
        }
        .joined(separator: "、")
    }

    /// debug 行後面掛上命中的行程樹，負控時（沒有終端機的 helper）一眼看得出沒被收進來。
    private static func describeTrees(_ snapshot: AgentProcessSnapshot) -> String {
        guard !snapshot.samples.isEmpty else { return "" }
        let list = snapshot.samples.map { "\($0.engine):\($0.pid)" }.joined(separator: ", ")
        return " [\(list)]"
    }

    // MARK: - 第一層：session log

    private struct LogScan: Sendable {
        var samples: [AgentSessionSample] = []
        var rootCount = 0
        var elapsed: Duration = .zero
        var slowest: (engine: String, elapsed: Duration)?
    }

    /// 目錄掃描。丟到背景 executor：`FileManager` 走的是同步 IO，
    /// 檔案再少也不該在 main actor 上做。
    private static func scanLogs(_ sources: [ResolvedAgentLogSource]) async -> LogScan {
        await Task.detached(priority: .utility) { collect(sources) }.value
    }

    /// 同步的那一半。`DirectoryEnumerator` 的迭代器在 async 情境下不可用，
    /// 所以走訪必須留在同步函式裡，由上面那支丟進背景。
    private nonisolated static func collect(_ sources: [ResolvedAgentLogSource]) -> LogScan {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey, .isDirectoryKey]
        let started = ContinuousClock.now
        var scan = LogScan()
        for source in sources {
            let rootStarted = ContinuousClock.now
            guard let walker = manager.enumerator(
                at: source.root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            scan.rootCount += 1
            let skipped = source.source.effectiveSkippedDirectories
            let maxDepth = source.source.maxDepth
            var visited = 0
            for case let url as URL in walker {
                visited += 1
                if visited > source.source.maxEntries { break }
                // 跳過名單與深度上限都不必先知道是不是目錄：對檔案呼叫
                // `skipDescendants()` 本來就沒有作用。
                if skipped.contains(url.lastPathComponent) {
                    walker.skipDescendants()
                    continue
                }
                if walker.level >= maxDepth { walker.skipDescendants() }
                // **副檔名先比對**：`resourceValues` 是這一輪最貴的一步，
                // 而絕大多數項目在這關就被刷掉（目錄也走這條）。
                guard source.source.accepts(pathExtension: url.pathExtension),
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let lastWrite = values.contentModificationDate
                else { continue }
                scan.samples.append(
                    AgentSessionSample(id: url.path, engine: source.engine, lastWrite: lastWrite)
                )
            }
            let rootElapsed = ContinuousClock.now - rootStarted
            if rootElapsed > (scan.slowest?.elapsed ?? .zero) {
                scan.slowest = (source.engine, rootElapsed)
            }
        }
        scan.elapsed = ContinuousClock.now - started
        return scan
    }

    // MARK: - 第二層：行程樹

    private struct ProcessScan: Sendable {
        var snapshot: AgentProcessSnapshot?
        var elapsed: Duration = .zero
    }

    private static func scanProcesses(
        _ sampler: (any AgentProcessSampling)?,
        matcher: AgentProcessMatcher
    ) async -> ProcessScan {
        guard let sampler else { return ProcessScan() }
        let started = ContinuousClock.now
        let snapshot = await sampler.snapshot(matcher: matcher)
        return ProcessScan(snapshot: snapshot, elapsed: ContinuousClock.now - started)
    }
}

private extension String {
    /// 行程樣本的 id 是 `pid:<n>`，log 樣本是檔案路徑。
    func dropPIDPrefix() -> String? {
        hasPrefix("pid:") ? String(dropFirst(4)) : nil
    }
}
