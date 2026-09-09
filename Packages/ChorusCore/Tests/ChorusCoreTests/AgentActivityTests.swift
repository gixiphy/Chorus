import Foundation
import Testing
@testable import ChorusCore

@Suite("AgentActivityPlanner")
struct AgentActivityTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func sample(_ id: String, engine: String = "Claude Code", agoSeconds: Double) -> AgentSessionSample {
        AgentSessionSample(id: id, engine: engine, lastWrite: now.addingTimeInterval(-agoSeconds))
    }

    @Test("Only sessions written within the grace window count as working")
    func graceWindow() {
        let samples = [
            sample("busy", agoSeconds: 3),
            sample("just-inside", agoSeconds: 299),
            sample("just-outside", agoSeconds: 300),
            sample("yesterday", agoSeconds: 86_400),
        ]
        let working = AgentActivityPlanner.workingSessions(samples, now: now)
        #expect(working.map(\.id) == ["busy", "just-inside"])
    }

    @Test("Most recently written session comes first")
    func ordering() {
        let samples = [
            sample("older", agoSeconds: 200),
            sample("newest", engine: "Codex", agoSeconds: 1),
            sample("middle", agoSeconds: 60),
        ]
        #expect(AgentActivityPlanner.workingSessions(samples, now: now).map(\.id)
            == ["newest", "middle", "older"])
    }

    @Test("A clock that jumped backwards still counts the session as working")
    func futureMTime() {
        // 檔案 mtime 落在未來（改過系統時鐘、或檔案從別台機器來）。
        // 寧可多醒一輪，也不要在 agent 跑到一半時讓機器睡著。
        let working = AgentActivityPlanner.workingSessions([sample("skewed", agoSeconds: -600)], now: now)
        #expect(working.map(\.id) == ["skewed"])
    }

    @Test("No samples means nothing is working")
    func empty() {
        #expect(AgentActivityPlanner.workingSessions([], now: now).isEmpty)
        #expect(AgentActivityPlanner.workingSessions([sample("cold", agoSeconds: 900)], now: now).isEmpty)
    }

    @Test("Grace window is caller-overridable")
    func customGrace() {
        let samples = [sample("a", agoSeconds: 30), sample("b", agoSeconds: 90)]
        #expect(AgentActivityPlanner.workingSessions(samples, now: now, graceSeconds: 60).map(\.id) == ["a"])
        #expect(AgentActivityPlanner.workingSessions(samples, now: now, graceSeconds: 120).count == 2)
    }
}
