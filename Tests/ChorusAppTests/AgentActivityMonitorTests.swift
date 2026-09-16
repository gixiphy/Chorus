import ChorusCore
import Foundation
import Synchronization
import Testing
@testable import Chorus

/// 掃描那一半（哪些檔算數、走到多深、mtime 怎麼讀）與兩層的合流。
/// 判定門檻本身在 `ChorusCoreTests/AgentActivityTests` 與
/// `AgentProcessActivityTests` 測，這裡只驗 App 端的組裝。
@MainActor
@Suite("AgentActivityMonitor")
struct AgentActivityMonitorTests {
    /// 腳本好的行程快照：每次 `snapshot` 吐一筆，用完之後重複最後一筆。
    private final class FakeProcessSampler: AgentProcessSampling {
        private let scripted: Mutex<[AgentProcessSnapshot]>
        private let seen = Mutex<[AgentProcessMatcher]>([])

        init(_ snapshots: [AgentProcessSnapshot]) {
            scripted = Mutex(snapshots)
        }

        /// 收到的 matcher（驗 `configureProcessDetection` 有把自訂名推下來）。
        var matchers: [AgentProcessMatcher] { seen.withLock { $0 } }

        func snapshot(matcher: AgentProcessMatcher) async -> AgentProcessSnapshot {
            seen.withLock { $0.append(matcher) }
            return scripted.withLock { queue in
                guard let first = queue.first else {
                    return AgentProcessSnapshot(samples: [], sampledAt: Date())
                }
                if queue.count > 1 { queue.removeFirst() }
                return first
            }
        }
    }

    /// 建一個假的 session log 根目錄。
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "chorus-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ relativePath: String, in root: URL, agoSeconds: Double) throws {
        let url = root.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{}\n".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-agoSeconds)], ofItemAtPath: url.path
        )
    }

    private func monitor(
        _ sources: [ResolvedAgentLogSource],
        sampler: (any AgentProcessSampling)? = nil,
        graceSeconds: Double = 300
    ) -> AgentActivityMonitor {
        AgentActivityMonitor(sources: sources, processSampler: sampler, graceSeconds: graceSeconds)
    }

    // MARK: - 第一層：session log

    @Test("Fresh session logs count, cold ones and non-jsonl files don't")
    func picksFreshLogs() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Codex 的 rollout 檔埋在 年/月/日 底下，走訪必須是遞迴的
        try write("2026/09/09/rollout-busy.jsonl", in: root, agoSeconds: 5)
        try write("cold.jsonl", in: root, agoSeconds: 3_600)
        try write("notes.md", in: root, agoSeconds: 5)

        let monitor = monitor([ResolvedAgentLogSource(engine: "Codex", root: root)])
        await monitor.refresh()

        #expect(monitor.isWorking)
        #expect(monitor.working.map { URL(fileURLWithPath: $0.id).lastPathComponent }
            == ["rollout-busy.jsonl"])
        #expect(monitor.engines == ["Codex"])
    }

    @Test("A root that doesn't exist is not an error, just no agents")
    func missingRootIsQuiet() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "chorus-agent-absent-\(UUID().uuidString)")
        let monitor = monitor([ResolvedAgentLogSource(engine: "Claude Code", root: missing)])
        await monitor.refresh()
        #expect(!monitor.isWorking)
    }

    @Test("The working/idle flip is what fires the callback, not membership churn")
    func notifiesOnlyOnFlip() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.jsonl", in: root, agoSeconds: 5)

        let monitor = monitor([ResolvedAgentLogSource(engine: "Claude Code", root: root)])
        var flips = 0
        monitor.onWorkingChanged = { flips += 1 }

        await monitor.refresh()
        #expect(flips == 1) // 收工 → 工作中
        try write("b.jsonl", in: root, agoSeconds: 5)
        await monitor.refresh()
        #expect(monitor.working.count == 2)
        #expect(flips == 1) // 多一個 session 不是翻面

        try FileManager.default.removeItem(at: root.appending(path: "a.jsonl"))
        try FileManager.default.removeItem(at: root.appending(path: "b.jsonl"))
        await monitor.refresh()
        #expect(!monitor.isWorking)
        #expect(flips == 2) // 工作中 → 收工
    }

    @Test("Stopping clears the state without firing the callback")
    func stopIsSilent() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.jsonl", in: root, agoSeconds: 5)

        let monitor = monitor([ResolvedAgentLogSource(engine: "Claude Code", root: root)])
        await monitor.refresh()
        var flips = 0
        monitor.onWorkingChanged = { flips += 1 }
        monitor.stop()
        #expect(!monitor.isWorking)
        #expect(flips == 0)
    }

    @Test("Skipped directories are not evidence — memory/ and node_modules/ get touched by other things")
    func skipsNoisyDirectories() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("memory/fresh.jsonl", in: root, agoSeconds: 5)
        try write("node_modules/pkg/fresh.jsonl", in: root, agoSeconds: 5)
        try write("real.jsonl", in: root, agoSeconds: 5)

        let monitor = monitor([ResolvedAgentLogSource(engine: "Claude Code", root: root)])
        await monitor.refresh()
        #expect(monitor.working.map { URL(fileURLWithPath: $0.id).lastPathComponent } == ["real.jsonl"])
    }

    @Test("maxDepth stops the walk — deep files cost IO every 30 seconds and are always stale")
    func honoursMaxDepth() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("top.jsonl", in: root, agoSeconds: 5)
        try write("a/deep.jsonl", in: root, agoSeconds: 5)

        let source = AgentLogSource(defaultPath: root.path, extensions: ["jsonl"], maxDepth: 1)
        let monitor = monitor([ResolvedAgentLogSource(engine: "Claude Code", root: root, source: source)])
        await monitor.refresh()
        #expect(monitor.working.map { URL(fileURLWithPath: $0.id).lastPathComponent } == ["top.jsonl"])
    }

    @Test("maxEntries caps the walk")
    func honoursMaxEntries() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<10 { try write("f\(index).jsonl", in: root, agoSeconds: 5) }

        let source = AgentLogSource(
            defaultPath: root.path, extensions: ["jsonl"], maxDepth: 3, maxEntries: 4
        )
        let monitor = monitor([ResolvedAgentLogSource(engine: "Claude Code", root: root, source: source)])
        await monitor.refresh()
        #expect(monitor.working.count == 4)
    }

    @Test("SQLite agents read db-wal only — db-shm mtime moves when any read-only tool polls it")
    func sqliteReadsWALOnly() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("state.db-wal", in: root, agoSeconds: 5)
        try write("state.db-shm", in: root, agoSeconds: 5)
        try write("state.db", in: root, agoSeconds: 5)

        let source = AgentLogSource(defaultPath: root.path, extensions: ["db-wal"], maxDepth: 1)
        let monitor = monitor([ResolvedAgentLogSource(engine: "Hermes", root: root, source: source)])
        await monitor.refresh()
        #expect(monitor.working.map { URL(fileURLWithPath: $0.id).lastPathComponent } == ["state.db-wal"])
    }

    // MARK: - 第二層：行程樹

    private func snapshot(
        _ samples: [AgentProcessSample], at date: Date = Date()
    ) -> AgentProcessSnapshot {
        AgentProcessSnapshot(samples: samples, sampledAt: date)
    }

    @Test("A process tree with no log evidence still counts, identified by pid")
    func processSamplesCount() async throws {
        let sampler = FakeProcessSampler([
            snapshot([
                AgentProcessSample(pid: 4_132, engine: "Cursor", agentID: "cursor", treeCPUSeconds: 1),
            ]),
        ])
        let monitor = monitor([], sampler: sampler)
        await monitor.refresh()
        #expect(monitor.engines == ["Cursor"])
        #expect(monitor.working.map(\.id) == ["pid:4132"])
    }

    @Test("A tree that stops burning CPU stays working until the grace runs out")
    func idleTreeRidesOutTheGrace() async throws {
        // 兩輪之間 CPU 完全沒長：第一次見到就算活動，接下來由 grace 收尾。
        let first = Date().addingTimeInterval(-60)
        let sampler = FakeProcessSampler([
            snapshot(
                [AgentProcessSample(pid: 4_132, engine: "Cursor", agentID: "cursor", treeCPUSeconds: 1)],
                at: first
            ),
            snapshot(
                [AgentProcessSample(pid: 4_132, engine: "Cursor", agentID: "cursor", treeCPUSeconds: 1)],
                at: Date()
            ),
        ])
        let monitor = monitor([], sampler: sampler)
        await monitor.refresh()
        await monitor.refresh()
        #expect(monitor.isWorking)
        #expect(monitor.working.map(\.lastWrite) == [first])
    }

    @Test("Turning process detection off drops the pid samples and the custom names reach the matcher")
    func configureProcessDetection() async throws {
        let sampler = FakeProcessSampler([
            snapshot([
                AgentProcessSample(pid: 4_132, engine: "Cursor", agentID: "cursor", treeCPUSeconds: 1),
            ]),
        ])
        let monitor = monitor([], sampler: sampler)
        monitor.configureProcessDetection(enabled: true, customProcessNames: ["yes"])
        await monitor.refresh()
        #expect(monitor.isWorking)
        #expect(sampler.matchers.last == AgentProcessMatcher(customProcessNames: ["yes"]))

        monitor.configureProcessDetection(enabled: false, customProcessNames: ["yes"])
        await monitor.refresh()
        #expect(!monitor.isWorking)
        #expect(sampler.matchers.count == 1) // 關掉之後不再去問
    }

    @Test("A Claude log and a Claude pid are one agent, not two")
    func dedupesAcrossLayers() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.jsonl", in: root, agoSeconds: 5)

        let sampler = FakeProcessSampler([
            snapshot([
                AgentProcessSample(pid: 4_132, engine: "Claude Code", agentID: "claude", treeCPUSeconds: 1),
            ]),
        ])
        let monitor = monitor(
            [ResolvedAgentLogSource(engine: "Claude Code", root: root)], sampler: sampler
        )
        await monitor.refresh()
        #expect(monitor.working.count == 1)
        #expect(monitor.working.map { URL(fileURLWithPath: $0.id).lastPathComponent } == ["a.jsonl"])
    }
}
