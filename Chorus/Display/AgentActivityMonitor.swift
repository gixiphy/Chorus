import ChorusCore
import Foundation
import Observation

/// 「有 agent 在工作時才防睡眠」的活動偵測（M9-2）。
///
/// 只看 agent CLI 的 session log 有沒有在長——理由見 `AgentSessionSample`。
/// 讀的是目錄列表與 mtime，**不開檔、不讀內容**，也不需要任何權限：
/// `~/.claude`、`~/.codex` 都不在 TCC 保護的目錄裡（Chorus 也沒有沙箱）。
///
/// 只在 Agent 模式啟用時輪詢。實測 618 個 log 檔掃一輪約 50ms，30 秒一次
/// 約是單核的 0.15%；掃描丟到背景 utility 佇列，不佔 main actor。
/// 週期抓 30 秒是因為它只需要比「系統待機倒數」快——那是以分鐘計的。
@MainActor
@Observable
final class AgentActivityMonitor {
    /// 一個 agent 的 session log 根目錄。
    struct Source: Sendable, Equatable {
        let engine: String
        let root: URL

        /// 目前認得的兩支：Claude Code 與 Codex。
        /// 其他 agent 只要 session log 也是「工作中才長」的檔案，加一列就會動。
        static var defaults: [Source] {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return [
                Source(engine: "Claude Code", root: home.appending(path: ".claude/projects")),
                Source(engine: "Codex", root: home.appending(path: ".codex/sessions")),
            ]
        }
    }

    /// 目前算「工作中」的 session，最近寫入的排前面。
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

    @ObservationIgnored private let sources: [Source]
    @ObservationIgnored private let graceSeconds: Double
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    init(
        sources: [Source] = Source.defaults,
        graceSeconds: Double = AgentActivityPlanner.defaultGraceSeconds,
        pollInterval: Duration = .seconds(30)
    ) {
        self.sources = sources
        self.graceSeconds = graceSeconds
        self.pollInterval = pollInterval
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
    }

    /// 掃一輪並套用。測試直接呼叫這支，不必等輪詢。
    func refresh() async {
        let samples = await Self.scan(sources)
        apply(samples)
    }

    private func apply(_ samples: [AgentSessionSample]) {
        let next = AgentActivityPlanner.workingSessions(samples, now: Date(), graceSeconds: graceSeconds)
        let wasWorking = isWorking
        working = next
        if wasWorking != isWorking { onWorkingChanged?() }
    }

    /// 目錄掃描。丟到背景 executor：`FileManager` 走的是同步 IO，
    /// 檔案再少也不該在 main actor 上做。
    private static func scan(_ sources: [Source]) async -> [AgentSessionSample] {
        await Task.detached(priority: .utility) { collect(sources) }.value
    }

    /// 同步的那一半。`DirectoryEnumerator` 的迭代器在 async 情境下不可用，
    /// 所以走訪必須留在同步函式裡，由上面那支丟進背景。
    private nonisolated static func collect(_ sources: [Source]) -> [AgentSessionSample] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        var samples: [AgentSessionSample] = []
        for source in sources {
            guard let walker = manager.enumerator(
                at: source.root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in walker {
                guard url.pathExtension == "jsonl",
                      let values = try? url.resourceValues(forKeys: keys),
                      values.isRegularFile == true,
                      let lastWrite = values.contentModificationDate
                else { continue }
                samples.append(
                    AgentSessionSample(id: url.path, engine: source.engine, lastWrite: lastWrite)
                )
            }
        }
        return samples
    }
}
