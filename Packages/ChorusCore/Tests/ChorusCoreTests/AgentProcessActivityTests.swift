import Foundation
import Testing
@testable import ChorusCore

@Suite("AgentProcessActivityPlanner")
struct AgentProcessActivityTests {
    private let start = Date(timeIntervalSince1970: 2_000_000)

    private func sample(
        pid: Int32 = 4132,
        engine: String = "Cursor CLI",
        cpu: Double,
        descendants: Set<Int32> = []
    ) -> AgentProcessSample {
        AgentProcessSample(
            pid: pid,
            engine: engine,
            agentID: "cursor",
            treeCPUSeconds: cpu,
            descendantPIDs: descendants
        )
    }

    private func snapshot(_ samples: [AgentProcessSample], at seconds: Double) -> AgentProcessSnapshot {
        AgentProcessSnapshot(samples: samples, sampledAt: start.addingTimeInterval(seconds))
    }

    /// 跑一串快照，回每一輪的樣本。
    private func run(_ snapshots: [AgentProcessSnapshot]) -> [[AgentSessionSample]] {
        var state = AgentProcessActivityPlanner.State()
        var rounds: [[AgentSessionSample]] = []
        for snapshot in snapshots {
            let result = AgentProcessActivityPlanner.step(state, snapshot: snapshot)
            state = result.state
            rounds.append(result.samples)
        }
        return rounds
    }

    // MARK: - 門檻

    @Test("A newly seen process counts as active right away")
    func firstSighting() {
        let result = AgentProcessActivityPlanner.step(
            AgentProcessActivityPlanner.State(),
            snapshot: snapshot([sample(cpu: 0)], at: 0)
        )
        #expect(result.samples == [
            AgentSessionSample(id: "pid:4132", engine: "Cursor CLI", lastWrite: start)
        ])
        #expect(result.state.previousAt == start)
        #expect(result.state.lastActive[4132] == start)
    }

    @Test("Half a CPU second per 30 seconds is the line")
    func thresholdOver30Seconds() {
        let below = run([snapshot([sample(cpu: 1)], at: 0), snapshot([sample(cpu: 1.49)], at: 30)])
        #expect(below[1].map(\.lastWrite) == [start])

        let onTheLine = run([snapshot([sample(cpu: 1)], at: 0), snapshot([sample(cpu: 1.5)], at: 30)])
        #expect(onTheLine[1].map(\.lastWrite) == [start.addingTimeInterval(30)])
    }

    @Test("The line is a rate, so a 60 second gap needs a full CPU second")
    func thresholdOver60Seconds() {
        let below = run([snapshot([sample(cpu: 0)], at: 0), snapshot([sample(cpu: 0.99)], at: 60)])
        #expect(below[1].map(\.lastWrite) == [start])

        let onTheLine = run([snapshot([sample(cpu: 0)], at: 0), snapshot([sample(cpu: 1)], at: 60)])
        #expect(onTheLine[1].map(\.lastWrite) == [start.addingTimeInterval(60)])
    }

    @Test("A caller-supplied fraction moves the line")
    func customFraction() {
        var state = AgentProcessActivityPlanner.State()
        state = AgentProcessActivityPlanner.step(state, snapshot: snapshot([sample(cpu: 0)], at: 0)).state
        let result = AgentProcessActivityPlanner.step(
            state,
            snapshot: snapshot([sample(cpu: 0.1)], at: 30),
            activeCPUFraction: 0.1 / 30
        )
        #expect(result.samples.map(\.lastWrite) == [start.addingTimeInterval(30)])
    }

    @Test("Samples closer than a second apart make no new verdict")
    func shortInterval() {
        // 取樣抖動除以極小的間隔會炸出假活動，所以這一輪不下判斷。
        let rounds = run([snapshot([sample(cpu: 0)], at: 0), snapshot([sample(cpu: 10)], at: 0.5)])
        #expect(rounds[1].map(\.lastWrite) == [start])
    }

    @Test("A negative CPU delta is treated as no work")
    func negativeDelta() {
        let rounds = run([snapshot([sample(cpu: 9)], at: 0), snapshot([sample(cpu: 3)], at: 30)])
        #expect(rounds[1].map(\.lastWrite) == [start])
    }

    @Test("A changed descendant set counts as activity on its own")
    func descendantChurn() {
        // 短命的子行程（ripgrep、編譯器）來去，本身就是有人在工作的跡證。
        let rounds = run([
            snapshot([sample(cpu: 1, descendants: [10, 11])], at: 0),
            snapshot([sample(cpu: 1, descendants: [10, 12])], at: 30),
            snapshot([sample(cpu: 1, descendants: [10, 12])], at: 60),
        ])
        #expect(rounds[1].map(\.lastWrite) == [start.addingTimeInterval(30)])
        #expect(rounds[2].map(\.lastWrite) == [start.addingTimeInterval(30)])
    }

    // MARK: - grace 與生命週期

    @Test("An idle tree drops out of the working list once the grace window closes")
    func idleTreeExpires() {
        let snapshots = (0..<6).map { snapshot([sample(cpu: 2)], at: Double($0) * 60) }
        let rounds = run(snapshots)
        for (index, samples) in rounds.enumerated() {
            let working = AgentActivityPlanner.workingSessions(
                samples,
                now: start.addingTimeInterval(Double(index) * 60),
                graceSeconds: 300
            )
            // 第 4 輪（240 秒）還在 grace 內，第 6 輪（300 秒）剛好出界。
            #expect(working.isEmpty == (index >= 5), "第 \(index + 1) 輪")
        }
        #expect(rounds[3].map(\.lastWrite) == [start])
    }

    @Test("A process that goes away is forgotten immediately")
    func processExit() {
        var state = AgentProcessActivityPlanner.State()
        state = AgentProcessActivityPlanner.step(state, snapshot: snapshot([sample(cpu: 1)], at: 0)).state
        let result = AgentProcessActivityPlanner.step(state, snapshot: snapshot([], at: 30))
        #expect(result.samples.isEmpty)
        #expect(result.state.previous.isEmpty)
        #expect(result.state.lastActive.isEmpty)
        #expect(result.state.previousAt == start.addingTimeInterval(30))
    }

    @Test("Trees are tracked one per pid")
    func multipleTrees() {
        let rounds = run([
            snapshot([sample(pid: 1, cpu: 0), sample(pid: 2, engine: "Claude Code", cpu: 0)], at: 0),
            snapshot([sample(pid: 1, cpu: 5), sample(pid: 2, engine: "Claude Code", cpu: 0)], at: 30),
        ])
        #expect(Set(rounds[1].map(\.id)) == ["pid:1", "pid:2"])
        let byID = Dictionary(uniqueKeysWithValues: rounds[1].map { ($0.id, $0.lastWrite) })
        #expect(byID["pid:1"] == start.addingTimeInterval(30))
        #expect(byID["pid:2"] == start)
    }

    // MARK: - 合併

    @Suite("AgentActivityMerger")
    struct MergerTests {
        private let now = Date(timeIntervalSince1970: 3_000_000)

        private func logSample(_ engine: String, agoSeconds: Double) -> AgentSessionSample {
            AgentSessionSample(
                id: "/logs/\(engine)-\(agoSeconds).jsonl",
                engine: engine,
                lastWrite: now.addingTimeInterval(-agoSeconds)
            )
        }

        private func processSample(_ pid: Int32, _ engine: String) -> AgentSessionSample {
            AgentSessionSample(id: "pid:\(pid)", engine: engine, lastWrite: now)
        }

        @Test("Nothing in, nothing out")
        func empty() {
            #expect(AgentActivityMerger.merge(logSamples: [], processSamples: [], now: now).isEmpty)
        }

        @Test("Log samples alone pass through")
        func logsOnly() {
            let logs = [logSample("Claude Code", agoSeconds: 5)]
            #expect(AgentActivityMerger.merge(logSamples: logs, processSamples: [], now: now) == logs)
        }

        @Test("Process samples alone pass through")
        func processesOnly() {
            let processes = [processSample(4132, "Cursor CLI")]
            #expect(AgentActivityMerger.merge(logSamples: [], processSamples: processes, now: now) == processes)
        }

        @Test("A fresh log sample hides the same engine's process samples")
        func deduplicatesByEngine() {
            // 同一個 session 被兩層都看到時，選單不該把它算成兩個。
            let merged = AgentActivityMerger.merge(
                logSamples: [logSample("Claude Code", agoSeconds: 5), logSample("Claude Code", agoSeconds: 40)],
                processSamples: [processSample(700, "Claude Code"), processSample(4132, "Cursor CLI")],
                now: now
            )
            #expect(merged.map(\.id) == [
                "/logs/Claude Code-5.0.jsonl",
                "/logs/Claude Code-40.0.jsonl",
                "pid:4132",
            ])
        }

        @Test("A stale log sample lets the process sample keep the machine awake")
        func staleLogKeepsProcessSample() {
            // log 冷掉了但行程樹還在燒 CPU：可能是這家 agent 的 log 根我們沒認出來。
            let merged = AgentActivityMerger.merge(
                logSamples: [logSample("Claude Code", agoSeconds: 900)],
                processSamples: [processSample(700, "Claude Code")],
                now: now
            )
            #expect(merged.map(\.id) == ["/logs/Claude Code-900.0.jsonl", "pid:700"])
            #expect(AgentActivityPlanner.workingSessions(merged, now: now).map(\.id) == ["pid:700"])
        }
    }
}
