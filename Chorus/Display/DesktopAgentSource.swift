import ChorusCore
import Darwin
import Foundation

/// 桌面行程掃描結果（可注入，避免測試碰真實行程）。
struct DesktopAgentProcess: Sendable, Equatable {
    var pid: Int32
    var comm: String
    var executablePath: String?
    var arguments: [String]
    /// 行程啟動時間（快取 key；來自 kinfo 或測試注入）。
    var startTime: Double
}

protocol DesktopAgentProcessListing: Sendable {
    func listDesktopCandidates() -> [DesktopAgentProcess]
}

/// 真實掃描：`listProcesses` + argv + `proc_pidpath`；start time 在本檔讀取（不改 Scanner）。
struct SystemDesktopAgentProcessLister: DesktopAgentProcessListing {
    func listDesktopCandidates() -> [DesktopAgentProcess] {
        let records = AgentProcessScanner.listProcesses()
        var result: [DesktopAgentProcess] = []
        for record in records where record.comm == "codex" || record.comm == "claude" {
            let argv = AgentProcessScanner.arguments(pid: record.pid) ?? []
            let path = Self.pidPath(record.pid)
            let start = Self.startTime(pid: record.pid) ?? 0
            result.append(
                DesktopAgentProcess(
                    pid: record.pid,
                    comm: record.comm,
                    executablePath: path,
                    arguments: argv,
                    startTime: start
                )
            )
        }
        return result
    }

    static func pidPath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// `kinfo_proc.kp_proc.p_starttime`（秒 + 微秒）。
    static func startTime(pid: Int32) -> Double? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let code = sysctl(&mib, 4, &info, &size, nil, 0)
        guard code == 0, size >= MemoryLayout<kinfo_proc>.stride else { return nil }
        let tv = info.kp_proc.p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
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

    private var enabled = true
    private var running = false
    private var pollTask: Task<Void, Never>?
    private var signatureCache: [String: Bool] = [:]
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
        self.enabled = enabled
    }

    func start() {
        guard !running else { return }
        running = true
        pollTask = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    func stop() {
        running = false
        pollTask?.cancel()
        pollTask = nil
        report = []
    }

    func clearEvidence() {
        report = []
        mtimeClamp.removeAll()
        signatureCache.removeAll()
    }

    func clearMtimeClamp() {
        mtimeClamp.removeAll()
    }

    func refresh() async {
        guard enabled, running else {
            report = []
            return
        }
        let instant = now()
        let processes = await Task.detached(priority: .utility) { [lister] in
            lister.listDesktopCandidates()
        }.value

        var next: [KeepAwakeSourceReport] = []
        let kindsPresent = classifiedKinds(from: processes)
        for kind in kindsPresent {
            // Fi A4：Claude Team 未確認 → 停用桌面 Claude 來源。
            if kind == .claudeApp, !DesktopAgentMatcher.claudeDesktopSourceEnabled {
                continue
            }
            guard let teamID = teamID(for: kind) else { continue }
            let matching = processes.filter {
                DesktopAgentMatcher.classify(
                    executablePath: $0.executablePath,
                    arguments: $0.arguments
                ) == kind
            }
            let signed = matching.filter { process in
                cachedSignature(process: process, teamID: teamID)
            }
            guard !signed.isEmpty else { continue }

            let mtimes = await Task.detached(priority: .utility) { [transcripts] in
                transcripts.latestMtimes(kind: kind)
            }.value
            guard let latest = mtimes.max(by: { $0.mtime < $1.mtime }) else { continue }
            let clamped = mtimeClamp.stabilize(id: latest.id, raw: latest.mtime, now: instant)
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

    private func cachedSignature(process: DesktopAgentProcess, teamID: String) -> Bool {
        let key = "\(process.pid):\(process.startTime):\(teamID)"
        if let cached = signatureCache[key] { return cached }
        let ok = verifier.teamIdentifierMatches(pid: process.pid, teamID: teamID)
        signatureCache[key] = ok
        return ok
    }
}
