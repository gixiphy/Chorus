import ChorusCore
import Darwin
import Foundation

/// 行程樹取樣來源。測試用假的餵腳本好的快照。
protocol AgentProcessSampling: Sendable {
    func snapshot(matcher: AgentProcessMatcher) async -> AgentProcessSnapshot
}

/// Agent 常亮的第二層偵測：掃全機行程，找出「有終端機的 agent 行程樹」並量它們的 CPU。
///
/// 涵蓋沒有全域 session log 的 agent（aider、crush…）與使用者自己補的 CLI 名字。
/// App 沒有沙箱，`sysctl`／`KERN_PROCARGS2`／`proc_pid_rusage` 對自己 UID 的行程
/// 都拿得到，不需要任何權限或 entitlement。
///
/// 成本控制在「便宜的先做」：`sysctl KERN_PROC_ALL` 一次拿回全機約 1,000 筆
/// （只讀 `p_comm`、`e_ppid`、`e_tdev`），逐個 syscall 的 argv 與 rusage **只對候選
/// 與候選的子孫**呼叫，一輪大約十來次。實測整輪 ≤ 10 ms。
struct AgentProcessScanner: AgentProcessSampling {
    /// 一筆行程的便宜欄位——全部來自那一次 `sysctl`。
    struct ProcessRecord: Sendable {
        let pid: Int32
        let ppid: Int32
        /// `kinfo_proc.p_comm`，**只有 16 個字**（比對規則見 `AgentProcessMatcher`）。
        let comm: String
        /// 有沒有控制終端機。IDE 內嵌與常駐 helper 沒有，是第一層過濾。
        let hasTTY: Bool
    }

    func snapshot(matcher: AgentProcessMatcher) async -> AgentProcessSnapshot {
        await Task.detached(priority: .utility) {
            Self.collect(records: Self.listProcesses(), matcher: matcher)
        }.value
    }

    // MARK: - 判定

    /// 從一份行程清單挑出 agent 行程樹並加總 CPU。
    ///
    /// 候選 ＝ 有 TTY 且 `p_comm` 值得再看（`isCandidate`）。候選才讀 argv 認人。
    /// 命中的根底下如果又有候選（`claude` spawn 出來的 `node`），**不另立一棵樹**——
    /// 否則同一個 session 會被算成兩個，而且 CPU 也會重複計。
    nonisolated static func collect(
        records: [ProcessRecord],
        matcher: AgentProcessMatcher
    ) -> AgentProcessSnapshot {
        var parents: [Int32: Int32] = [:]
        var children: [Int32: [Int32]] = [:]
        for record in records {
            parents[record.pid] = record.ppid
            children[record.ppid, default: []].append(record.pid)
        }

        var matches: [Int32: AgentProcessMatcher.Match] = [:]
        for record in records where record.hasTTY && matcher.isCandidate(comm: record.comm) {
            let match: AgentProcessMatcher.Match?
            if let argv = arguments(pid: record.pid) {
                match = matcher.match(arguments: argv)
            } else {
                // zombie 或讀不到 argv：退回只有 16 字的 comm，前綴與截斷比對還救得回來。
                match = matcher.match(processName: record.comm)
            }
            if let match { matches[record.pid] = match }
        }

        var samples: [AgentProcessSample] = []
        for pid in matches.keys.sorted() {
            guard let match = matches[pid],
                  !hasMatchedAncestor(of: pid, parents: parents, matches: matches)
            else { continue }
            // 根自己的 own ＋ 它已回收的子行程（BSD 的 child times 是遞迴累積的，
            // 短命的 ripgrep／編譯器死了也還算在裡面）。
            var total = cpuSeconds(pid: pid).map { $0.own + $0.reapedChildren } ?? 0
            var descendants: Set<Int32> = []
            var queue = children[pid] ?? []
            while let child = queue.popLast() {
                guard descendants.insert(child).inserted else { continue }
                if let cpu = cpuSeconds(pid: child) { total += cpu.own }
                queue.append(contentsOf: children[child] ?? [])
            }
            samples.append(
                AgentProcessSample(
                    pid: pid,
                    engine: match.engine,
                    agentID: match.agentID,
                    treeCPUSeconds: total,
                    descendantPIDs: descendants
                )
            )
        }
        return AgentProcessSnapshot(samples: samples, sampledAt: Date())
    }

    /// 往上找有沒有已經命中的祖先。`launchd`（pid 1）與斷掉的鏈都會自然收尾，
    /// 上限只是防 `ppid` 成環時空轉。
    private nonisolated static func hasMatchedAncestor(
        of pid: Int32,
        parents: [Int32: Int32],
        matches: [Int32: AgentProcessMatcher.Match]
    ) -> Bool {
        var current = parents[pid]
        var hops = 0
        while let parent = current, parent > 1, hops < 64 {
            if matches[parent] != nil { return true }
            current = parents[parent]
            hops += 1
        }
        return false
    }

    // MARK: - Darwin

    /// 全機行程的便宜欄位。Darwin 型別不離開這支函式。
    nonisolated static func listProcesses() -> [ProcessRecord] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        // 兩次呼叫之間行程數會變，多要一成的空間免得剛好在邊界 ENOMEM。
        let capacity = (size + size / 8) / MemoryLayout<kinfo_proc>.stride + 1
        var buffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        var actual = capacity * MemoryLayout<kinfo_proc>.stride
        let code = buffer.withUnsafeMutableBytes { raw in
            sysctl(&mib, UInt32(mib.count), raw.baseAddress, &actual, nil, 0)
        }
        guard code == 0 else { return [] }
        let count = actual / MemoryLayout<kinfo_proc>.stride
        return (0..<count).map { index in
            var entry = buffer[index]
            let comm = withUnsafeBytes(of: &entry.kp_proc.p_comm) { raw in
                raw.baseAddress.map { String(cString: $0.assumingMemoryBound(to: CChar.self)) } ?? ""
            }
            return ProcessRecord(
                pid: entry.kp_proc.p_pid,
                ppid: entry.kp_eproc.e_ppid,
                comm: comm,
                // `NODEV` 是 `(dev_t)(-1)`，Swift 匯不進這個 cast macro。
                hasTTY: entry.kp_eproc.e_tdev != -1
            )
        }
    }

    /// 這個行程的 argv。別人的行程、zombie、剛結束的都回 nil。
    nonisolated static func arguments(pid: Int32) -> [String]? {
        guard argumentsMax > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: argumentsMax)
        var length = argumentsMax
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &length, nil, 0) == 0,
              length > MemoryLayout<Int32>.size
        else { return nil }

        // 版面：argc（4 bytes）、exec path、補齊的 NUL、然後 argc 個 NUL 結尾字串。
        var argc: Int32 = 0
        withUnsafeMutableBytes(of: &argc) { destination in
            buffer.withUnsafeBytes { source in
                destination.copyBytes(
                    from: UnsafeRawBufferPointer(rebasing: source[0..<MemoryLayout<Int32>.size])
                )
            }
        }
        guard argc > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < length, buffer[index] != 0 { index += 1 }
        while index < length, buffer[index] == 0 { index += 1 }

        var result: [String] = []
        var current: [CChar] = []
        while index < length, result.count < Int(argc) {
            if buffer[index] == 0 {
                current.append(0)
                result.append(String(cString: current))
                current.removeAll(keepingCapacity: true)
            } else {
                current.append(buffer[index])
            }
            index += 1
        }
        return result.isEmpty ? nil : result
    }

    /// 這個行程累計燒掉的 CPU 秒數（自己的，與已回收子行程的）。
    ///
    /// `rusage_info` 的時間是 **mach 絕對時間單位**，不是奈秒：Apple Silicon 的
    /// timebase 是 125/3，不換算會差 40 倍。
    nonisolated static func cpuSeconds(pid: Int32) -> (own: Double, reapedChildren: Double)? {
        var usage = rusage_info_v4()
        let code = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard code == 0 else { return nil }
        return (
            own: Double(usage.ri_user_time &+ usage.ri_system_time) * timebaseScale,
            reapedChildren: Double(usage.ri_child_user_time &+ usage.ri_child_system_time) * timebaseScale
        )
    }

    /// mach 絕對時間單位 → 秒。
    private static let timebaseScale: Double = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else { return 1e-9 }
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    /// `KERN_ARGMAX` 一台機器上是固定的（1 MB），問一次就好。
    private static let argumentsMax: Int = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &value, &size, nil, 0) == 0, value > 0 else { return 0 }
        return Int(value)
    }()
}
