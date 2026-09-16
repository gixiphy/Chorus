import ChorusCore
import Darwin
import Foundation
import Testing
@testable import Chorus

/// 真的去問核心。這些是「Darwin 版面有沒有被我讀錯」的護欄——
/// 型別、偏移、單位換算錯掉時，上層的判定會安靜地永遠說「沒人在工作」。
@Suite("AgentProcessScanner")
struct AgentProcessScannerTests {
    private typealias Record = AgentProcessScanner.ProcessRecord

    @Test("The process list contains this very process, with the parent and TTY the kernel reports")
    func listsSelf() throws {
        let records = AgentProcessScanner.listProcesses()
        #expect(records.count > 10)
        let me = try #require(records.first { $0.pid == getpid() })
        #expect(me.ppid == getppid())
        // `e_tdev` 是**控制終端機**，不是「fd 0 是不是 tty」——測試 host 兩者不一致
        // （stdin 接著終端機，但沒有控制終端機）。能開 `/dev/tty` 才是同一件事。
        let terminal = open("/dev/tty", O_RDONLY)
        if terminal >= 0 { close(terminal) }
        #expect(me.hasTTY == (terminal >= 0))
        // launchd 永遠沒有控制終端機：欄位全讀成 true 的話這裡會紅。
        #expect(records.first { $0.pid == 1 }?.hasTTY == false)
        #expect(!me.comm.isEmpty)
        // p_comm 只有 16 個字——比對規則就是為了這件事存在的。
        #expect(records.allSatisfy { $0.comm.utf8.count <= 16 })
    }

    @Test("argv comes back for our own process; another user's process is nil, not a crash")
    func readsArguments() throws {
        let mine = try #require(AgentProcessScanner.arguments(pid: getpid()))
        #expect(!mine.isEmpty)
        #expect(!(mine.first ?? "").isEmpty)
        // launchd 是 root 的，讀不到就該安靜回 nil。
        #expect(AgentProcessScanner.arguments(pid: 1) == nil)
        #expect(AgentProcessScanner.arguments(pid: 999_999) == nil)
    }

    @Test("CPU seconds are real seconds — mach absolute units are off by a factor of 40 here")
    func cpuSecondsUseTheTimebase() throws {
        let before = try #require(AgentProcessScanner.cpuSeconds(pid: getpid()))
        let deadline = ContinuousClock.now + .milliseconds(50)
        var spin = 0.0
        while ContinuousClock.now < deadline { spin += 1 }
        #expect(spin > 0)
        let after = try #require(AgentProcessScanner.cpuSeconds(pid: getpid()))

        let burned = after.own - before.own
        #expect(burned > 0.02)
        #expect(burned < 0.5)
        #expect(after.reapedChildren >= before.reapedChildren)
        #expect(AgentProcessScanner.cpuSeconds(pid: 999_999) == nil)
    }

    // MARK: - 合成紀錄

    /// 用不存在的 pid：`arguments`／`cpuSeconds` 都會回 nil，
    /// 判定就只剩下「TTY ＋ comm ＋ 親子關係」這幾條要驗的規則。
    @Test("Only processes with a TTY are candidates")
    func requiresTTY() {
        let records = [
            Record(pid: 900_001, ppid: 1, comm: "claude", hasTTY: false),
            Record(pid: 900_002, ppid: 1, comm: "codex", hasTTY: true),
        ]
        let snapshot = AgentProcessScanner.collect(records: records, matcher: AgentProcessMatcher())
        #expect(snapshot.samples.map(\.pid) == [900_002])
        #expect(snapshot.samples.map(\.engine) == ["Codex"])
    }

    @Test("A node under a matched root joins its tree instead of starting a second one")
    func descendantsDoNotStartTheirOwnTree() throws {
        let records = [
            Record(pid: 900_010, ppid: 1, comm: "claude", hasTTY: true),
            Record(pid: 900_011, ppid: 900_010, comm: "node", hasTTY: true),
            Record(pid: 900_012, ppid: 900_011, comm: "rg", hasTTY: true),
        ]
        let snapshot = AgentProcessScanner.collect(records: records, matcher: AgentProcessMatcher())
        #expect(snapshot.samples.count == 1)
        let tree = try #require(snapshot.samples.first)
        #expect(tree.pid == 900_010)
        #expect(tree.descendantPIDs == [900_011, 900_012])
    }

    @Test("Custom process names pick up CLIs the registry has never heard of")
    func customNamesMatch() {
        let records = [Record(pid: 900_020, ppid: 1, comm: "yes", hasTTY: true)]
        let matcher = AgentProcessMatcher(customProcessNames: ["yes"])
        #expect(AgentProcessScanner.collect(records: records, matcher: matcher).samples.count == 1)
        #expect(AgentProcessScanner.collect(records: records, matcher: AgentProcessMatcher())
            .samples.isEmpty)
    }

    @Test("Two sibling agents are two trees")
    func siblingsAreSeparateTrees() {
        let records = [
            Record(pid: 900_030, ppid: 1, comm: "claude", hasTTY: true),
            Record(pid: 900_031, ppid: 1, comm: "cursor-agent", hasTTY: true),
        ]
        let snapshot = AgentProcessScanner.collect(records: records, matcher: AgentProcessMatcher())
        #expect(snapshot.samples.map(\.engine).sorted() == ["Claude Code", "Cursor CLI"])
    }
}
