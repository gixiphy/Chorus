import ChorusCore
import Darwin
import Foundation

/// 桌面行程掃描結果（可注入，避免測試碰真實行程）。
struct DesktopAgentProcess: Sendable, Equatable {
    var pid: Int32
    var comm: String
    var executablePath: String?
    var arguments: [String]
    /// 行程啟動時間；查詢失敗為 nil（不得用 0 當快取 key，C7-4）。
    var startTime: Double?
    /// 行程 uid；必須等於目前使用者（§14.3）。
    var uid: uid_t?
}

protocol DesktopAgentProcessListing: Sendable {
    func listDesktopCandidates() -> [DesktopAgentProcess]
}

/// 真實掃描：`listProcesses` + argv + `proc_pidpath`；start time／uid 在本檔讀取（不改 Scanner）。
struct SystemDesktopAgentProcessLister: DesktopAgentProcessListing {
    func listDesktopCandidates() -> [DesktopAgentProcess] {
        let records = AgentProcessScanner.listProcesses()
        let currentUID = getuid()
        var result: [DesktopAgentProcess] = []
        for record in records where record.comm == "codex" || record.comm == "claude" {
            if let candidate = Self.stableCandidate(
                pid: record.pid, comm: record.comm, currentUID: currentUID,
                identity: { Self.identity(pid: record.pid) },
                arguments: { AgentProcessScanner.arguments(pid: record.pid) },
                path: { Self.pidPath(record.pid) }
            ) { result.append(candidate) }
        }
        return result
    }

    /// Metadata reads must be bracketed by one identity and repeated across exec.
    static func stableCandidate(
        pid: Int32, comm: String, currentUID: uid_t,
        identity: () -> (startTime: Double, uid: uid_t)?,
        arguments: () -> [String]?, path: () -> String?
    ) -> DesktopAgentProcess? {
        guard let before = identity(), before.uid == currentUID else { return nil }
        guard let argv = arguments(), let executable = path(),
              let after = identity(), after.startTime == before.startTime,
              after.uid == before.uid, path() == executable, arguments() == argv,
              let final = identity(), final.startTime == before.startTime,
              final.uid == before.uid else { return nil }
        return DesktopAgentProcess(pid: pid, comm: comm, executablePath: executable,
                                   arguments: argv, startTime: before.startTime, uid: before.uid)
    }

    static func pidPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `kinfo_proc` 的 start time 與 uid；任一失敗回 nil。
    static func identity(pid: Int32) -> (startTime: Double, uid: uid_t)? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let code = sysctl(&mib, 4, &info, &size, nil, 0)
        guard code == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let tv = info.kp_proc.p_starttime
        let start = Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
        guard start > 0 else { return nil }
        let uid = info.kp_eproc.e_ucred.cr_uid
        return (start, uid)
    }

    /// `kinfo_proc.kp_proc.p_starttime`（秒 + 微秒）。
    static func startTime(pid: Int32) -> Double? {
        identity(pid: pid)?.startTime
    }
}

protocol DesktopTranscriptScanning: Sendable {
    /// 回傳 (path, mtime)；只讀 mtime，不讀內容。
    func latestMtimes(kind: DesktopAgentKind) -> [(id: String, mtime: Date)]
}

struct RegistryDesktopTranscriptScanner: DesktopTranscriptScanning {
    var home: URL
    var environment: [String: String]

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.home = home
        self.environment = environment
    }

    func latestMtimes(kind: DesktopAgentKind) -> [(id: String, mtime: Date)] {
        switch kind {
        case .codexApp:
            return scanCodex()
        case .claudeApp:
            return scanClaude()
        }
    }

    private func scanCodex() -> [(id: String, mtime: Date)] {
        guard let definition = AgentRegistry.all.first(where: { $0.id == "codex" }) else { return [] }
        var samples: [(id: String, mtime: Date)] = []
        for source in definition.logSources {
            let root = source.resolveRoot(home: home, environment: environment)
            samples.append(contentsOf: Self.scan(
                root: root,
                source: source,
                namePrefix: DesktopAgentMatcher.codexRolloutPrefix
            ))
        }
        return samples
    }

    private func scanClaude() -> [(id: String, mtime: Date)] {
        var samples: [(id: String, mtime: Date)] = []
        for relative in DesktopAgentMatcher.claudeTranscriptRoots {
            let source = AgentLogSource(
                defaultPath: relative,
                extensions: ["jsonl"],
                maxDepth: 4
            )
            let root = source.resolveRoot(home: home, environment: environment)
            samples.append(contentsOf: Self.scan(root: root, source: source, namePrefix: nil))
        }
        return samples
    }

    private static func scan(
        root: URL,
        source: AgentLogSource,
        namePrefix: String?
    ) -> [(id: String, mtime: Date)] {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let walker = manager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [(id: String, mtime: Date)] = []
        let skipped = source.effectiveSkippedDirectories
        var visited = 0
        for case let url as URL in walker {
            visited += 1
            if visited > source.maxEntries { break }
            if skipped.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            if walker.level >= source.maxDepth { walker.skipDescendants() }
            if let namePrefix, !url.lastPathComponent.hasPrefix(namePrefix) { continue }
            guard source.accepts(pathExtension: url.pathExtension),
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let mtime = values.contentModificationDate
            else { continue }
            result.append((url.path, mtime))
        }
        return result
    }
}

@MainActor
final class DesktopAgentSource: KeepAwakeSource {
    private(set) var report: [KeepAwakeSourceReport] = []
    var onChange: (() -> Void)?

    /// 測試縫：覆寫「目前使用者」uid。
    var currentUID: () -> uid_t = { getuid() }
    /// 測試可見：簽章快取大小。
    var signatureCacheCount: Int { signatureCache.count }

    private var enabled = true
    private var running = false
    private var pollTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var signatureCache: [String: DesktopAgentProcess] = [:]
    private var refreshing = false
    private var mtimeClamp = KeepAwakeMtimeClampCache()

    private let lister: any DesktopAgentProcessListing
    private let verifier: any CodeSignatureVerifying
    private let transcripts: any DesktopTranscriptScanning
    private let now: () -> Date
    private let pollInterval: Duration
    private let graceSeconds: Double

    init(
        lister: any DesktopAgentProcessListing = SystemDesktopAgentProcessLister(),
        verifier: any CodeSignatureVerifying = SystemCodeSignatureVerifier(),
        transcripts: any DesktopTranscriptScanning = RegistryDesktopTranscriptScanner(),
        now: @escaping () -> Date = Date.init,
        pollInterval: Duration = .seconds(30),
        graceSeconds: Double = KeepAwakeBusyAggregator.defaultGraceSeconds
    ) {
        self.lister = lister
        self.verifier = verifier
        self.transcripts = transcripts
        self.now = now
        self.pollInterval = pollInterval
        self.graceSeconds = graceSeconds
    }

    func configure(enabled: Bool) {
        if self.enabled != enabled {
            generation &+= 1
        }
        self.enabled = enabled
    }

    func start() {
        start(schedulePolling: true)
    }

    /// 測試手動 `refresh` 時傳 `schedulePolling: false`，避免與輪詢疊加。
    func start(schedulePolling: Bool) {
        guard !running else { return }
        running = true
        guard schedulePolling else { return }
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    func stop() {
        generation &+= 1
        running = false
        pollTask?.cancel()
        pollTask = nil
        report = []
        signatureCache.removeAll()
    }

    func clearEvidence() {
        generation &+= 1
        report = []
        mtimeClamp.removeAll()
        signatureCache.removeAll()
    }

    func clearMtimeClamp() {
        mtimeClamp.removeAll()
    }

    func refresh() async {
        let gen = generation
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }
        guard enabled, running else {
            report = []
            return
        }
        let instant = now()
        let expectedUID = currentUID()
        let processes = await Task.detached(priority: .utility) { [lister] in
            lister.listDesktopCandidates()
        }.value
        guard generation == gen, enabled, running else { return }

        let accepted = processes.filter { process in
            guard let start = process.startTime, start > 0,
                  let uid = process.uid, uid == expectedUID
            else { return false }
            return true
        }

        var next: [KeepAwakeSourceReport] = []
        var liveCacheKeys = Set<String>()
        var liveMtimeIDs = Set<String>()
        let kindsPresent = classifiedKinds(from: accepted)
        for kind in kindsPresent {
            // Fi A4：Claude Team 未確認 → 停用桌面 Claude 來源。
            if kind == .claudeApp, !DesktopAgentMatcher.claudeDesktopSourceEnabled {
                continue
            }
            guard let teamID = teamID(for: kind) else { continue }
            let matching = accepted.filter {
                DesktopAgentMatcher.classify(
                    executablePath: $0.executablePath,
                    arguments: $0.arguments
                ) == kind
            }

            var signed: [DesktopAgentProcess] = []
            for process in matching {
                let ok = await verifySignature(process: process, teamID: teamID, generation: gen)
                guard generation == gen, enabled, running else { return }
                if ok {
                    signed.append(process)
                }
            }
            guard !signed.isEmpty else { continue }

            let mtimes = await Task.detached(priority: .utility) { [transcripts] in
                transcripts.latestMtimes(kind: kind)
            }.value
            guard generation == gen, enabled, running else { return }
            let survivors = await Task.detached(priority: .utility) { [lister, signed] in
                let live = lister.listDesktopCandidates()
                return signed.filter { live.contains($0) }
            }.value
            guard generation == gen, enabled, running else { return }
            guard !survivors.isEmpty else { continue }
            for process in survivors {
                if let start = process.startTime {
                    liveCacheKeys.insert(cacheKey(pid: process.pid, start: start, teamID: teamID))
                }
            }
            // Normalize every live sample before choosing the newest normalized evidence.
            let normalized = mtimes.map {
                mtimeClamp.stabilize(id: $0.id, raw: $0.mtime, now: instant)
            }
            liveMtimeIDs.formUnion(mtimes.map(\.id))
            guard let clamped = normalized.max() else { continue }
            // 行程在且驗簽通過，但 mtime 必須在寬限內才算（report 用 isWorkingNow=false）。
            guard instant.timeIntervalSince(clamped) < graceSeconds else { continue }

            next.append(
                KeepAwakeSourceReport(
                    id: kind == .codexApp ? "desktop.codex" : "desktop.claude",
                    kind: .desktopApp,
                    displayName: kind == .codexApp ? "Codex App" : "Claude App",
                    detail: nil,
                    isWorkingNow: false,
                    lastWorkingAt: clamped,
                    health: .ok
                )
            )
        }

        // C7-4：只保留仍存活且通過的身分；終止行程的快取清掉。
        signatureCache = signatureCache.filter { liveCacheKeys.contains($0.key) }
        mtimeClamp.retainIds(liveMtimeIDs)

        let previous = report
        report = next
        if previous != report {
            onChange?()
        }
    }

    // MARK: - Helpers

    private func classifiedKinds(from processes: [DesktopAgentProcess]) -> [DesktopAgentKind] {
        var seen = Set<DesktopAgentKind>()
        var order: [DesktopAgentKind] = []
        for process in processes {
            guard let kind = DesktopAgentMatcher.classify(
                executablePath: process.executablePath,
                arguments: process.arguments
            ) else { continue }
            if seen.insert(kind).inserted {
                order.append(kind)
            }
        }
        return order
    }

    private func teamID(for kind: DesktopAgentKind) -> String? {
        switch kind {
        case .codexApp:
            return DesktopAgentMatcher.codexTeamID
        case .claudeApp:
            return DesktopAgentMatcher.claudeTeamID
        }
    }

    private func cacheKey(pid: Int32, start: Double, teamID: String) -> String {
        "\(pid):\(start):\(teamID)"
    }

    private func isLive(_ process: DesktopAgentProcess) async -> Bool {
        await Task.detached(priority: .utility) { [lister] in
            lister.listDesktopCandidates().contains(process)
        }.value
    }

    private func verifySignature(
        process: DesktopAgentProcess,
        teamID: String,
        generation gen: UInt64
    ) async -> Bool {
        guard let start = process.startTime, start > 0,
              let uid = process.uid, uid == currentUID()
        else { return false }

        let key = cacheKey(pid: process.pid, start: start, teamID: teamID)
        let liveBefore = await isLive(process)
        guard generation == gen, liveBefore else { return false }
        if signatureCache[key] == process { return true }

        let pid = process.pid
        let verifier = verifier
        let ok = await Task.detached(priority: .utility) {
            verifier.teamIdentifierMatches(pid: pid, teamID: teamID)
        }.value
        guard generation == gen else { return false }

        // 驗簽後再對身分：PID 重用／uid 變化則作廢（C7-4）。
        let stillValid = await isLive(process)
        guard generation == gen else { return false }

        let accepted = ok && stillValid
        if accepted {
            signatureCache[key] = process
        }
        // 失敗不快取成功，避免短暫失敗鎖死；也不快取失敗以免 PID 重用誤判。
        return accepted
    }
}
