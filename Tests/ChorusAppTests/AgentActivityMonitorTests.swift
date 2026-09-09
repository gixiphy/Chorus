import ChorusCore
import Foundation
import Testing
@testable import Chorus

/// 掃描那一半（哪些檔算數、mtime 怎麼讀）。判定門檻本身在
/// `ChorusCoreTests/AgentActivityTests` 測，這裡只驗目錄走訪。
@MainActor
@Suite("AgentActivityMonitor")
struct AgentActivityMonitorTests {
    /// 建一個假的 session log 根目錄，回傳 (root, 清理用 closure)。
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

    @Test("Fresh session logs count, cold ones and non-jsonl files don't")
    func picksFreshLogs() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // Codex 的 rollout 檔埋在 年/月/日 底下，走訪必須是遞迴的
        try write("2026/09/09/rollout-busy.jsonl", in: root, agoSeconds: 5)
        try write("cold.jsonl", in: root, agoSeconds: 3_600)
        try write("notes.md", in: root, agoSeconds: 5)

        let monitor = AgentActivityMonitor(
            sources: [.init(engine: "Codex", root: root)], graceSeconds: 300
        )
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
        let monitor = AgentActivityMonitor(sources: [.init(engine: "Claude Code", root: missing)])
        await monitor.refresh()
        #expect(!monitor.isWorking)
    }

    @Test("The working/idle flip is what fires the callback, not membership churn")
    func notifiesOnlyOnFlip() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("a.jsonl", in: root, agoSeconds: 5)

        let monitor = AgentActivityMonitor(
            sources: [.init(engine: "Claude Code", root: root)], graceSeconds: 300
        )
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

        let monitor = AgentActivityMonitor(
            sources: [.init(engine: "Claude Code", root: root)], graceSeconds: 300
        )
        await monitor.refresh()
        var flips = 0
        monitor.onWorkingChanged = { flips += 1 }
        monitor.stop()
        #expect(!monitor.isWorking)
        #expect(flips == 0)
    }
}
