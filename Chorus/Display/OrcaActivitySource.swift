import AppKit
import ChorusCore
import Darwin
import Foundation

/// `orca worktree ps --json` 的可注入執行介面（測試用假 runner；不打真實 runtime）。
protocol OrcaCommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        stdoutLimit: Int
    ) async -> OrcaCommandRunResult
}

struct OrcaCommandRunResult: Sendable {
    var exitCode: Int32?
    var stdout: Data
    var stderr: Data
    var timedOut: Bool
    var killed: Bool
    var stdoutOverflowed: Bool

    init(
        exitCode: Int32?,
        stdout: Data,
        stderr: Data,
        timedOut: Bool,
        killed: Bool,
        stdoutOverflowed: Bool = false
    ) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.killed = killed
        self.stdoutOverflowed = stdoutOverflowed
    }
}

/// C7-7：CLI 失敗時是否可誠實宣稱行程偵測退路。
enum OrcaFallbackCapability: Sendable, Equatable {
    /// 第二層關閉。
    case unavailable
    /// 第二層開啟，但 Orca PTY 命中未驗證（M-6）。
    case unverified
    /// 測試／未來已確認可涵蓋時才用「改用行程偵測」。
    case active
}

protocol OrcaPresenceChecking: Sendable {
    func isOrcaRunning() -> Bool
}

struct WorkspaceOrcaPresenceChecker: OrcaPresenceChecking {
    func isOrcaRunning() -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            if let id = app.bundleIdentifier, OrcaWorktreeStatus.knownBundleIDs.contains(id) {
                return true
            }
            if let path = app.bundleURL?.path, OrcaWorktreeStatus.knownAppPaths.contains(path) {
                return true
            }
        }
        // 退路：comm == "Orca"（不需 argv）。I/O 應在 utility；呼叫端負責。
        return AgentProcessScanner.listProcesses().contains { $0.comm == "Orca" }
    }
}

enum OrcaCLILocator {
    static let defaultPATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    static func resolve(
        override: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: (String) -> Bool = { path in
            var isDir: ObjCBool = false
            let ok = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
            return ok && !isDir.boolValue
        },
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        var candidates: [String] = []
        if let override, !override.isEmpty {
            candidates.append(override)
        }
        for raw in OrcaWorktreeStatus.defaultCLICandidates {
            if raw.hasPrefix("~/") {
                let rest = String(raw.dropFirst(2))
                candidates.append(home.appending(path: rest).path)
            } else {
                candidates.append(raw)
            }
        }
        for path in candidates {
            let standardized = (path as NSString).standardizingPath
            guard fileExists(standardized), isExecutable(standardized) else { continue }
            return standardized
        }
        return nil
    }
}

// MARK: - Bounded concurrent pipe drain (C7-3)

/// 執行期間並行排空 pipe；超限丟棄後續位元組；讀取有上限等待。
enum OrcaPipeDrain {
    static let stderrCap = 2_048

    final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var overflowed = false
        private let limit: Int

        init(limit: Int) { self.limit = limit }

        func append(_ chunk: Data) {
            lock.lock()
            defer { lock.unlock() }
            if overflowed { return }
            if data.count + chunk.count > limit {
                let room = max(0, limit - data.count)
                if room > 0 { data.append(chunk.prefix(room)) }
                overflowed = true
            } else {
                data.append(chunk)
            }
        }

        func snapshot() -> (Data, Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (data, overflowed)
        }
    }

    enum ReadResult { case bytes(Data), eof, wouldBlock, failed }

    /// A bounded nonblocking turn; EOF is distinct from EAGAIN and errors.
    static func drain(into buffer: Buffer, read: () -> ReadResult) -> ReadResult {
        for _ in 0..<64 {
            switch read() {
            case let .bytes(data): buffer.append(data)
            case .eof: return .eof
            case .wouldBlock: return .wouldBlock
            case .failed: return .failed
            }
        }
        return .wouldBlock
    }

    static func readAvailable(_ descriptor: Int32) -> ReadResult {
        var bytes = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 { return .bytes(Data(bytes.prefix(count))) }
        if count == 0 { return .eof }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { return .wouldBlock }
        return .failed
    }

}

/// Monotonic cleanup policy, independent of Process and pipes for deterministic tests.
struct OrcaCommandLifecycle {
    enum Action: Equatable { case wait, terminate, kill, finish(incomplete: Bool) }
    let timeout: Duration
    private var termAt: Duration?
    private var exitedAt: Duration?
    private(set) var timedOut = false
    private(set) var killed = false

    mutating func step(elapsed: Duration, childRunning: Bool, drainsComplete: Bool) -> Action {
        if childRunning {
            if termAt == nil, elapsed >= timeout {
                timedOut = true
                termAt = elapsed
                return .terminate
            }
            if let termAt, elapsed >= termAt + .seconds(1), !killed {
                killed = true
                return .kill
            }
            return .wait // even after KILL: ownership ends only after confirmed exit
        }
        if drainsComplete { return .finish(incomplete: false) }
        if exitedAt == nil { exitedAt = elapsed }
        if let exitedAt, elapsed >= exitedAt + .seconds(1) {
            return .finish(incomplete: true)
        }
        return .wait
    }
}

/// 真實子行程 runner：並行排空 pipe、5 秒逾時、SIGTERM→1s→SIGKILL、stdout 上限 4 MB。
struct ProcessOrcaCommandRunner: OrcaCommandRunning {
    func run(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        stdoutLimit: Int
    ) async -> OrcaCommandRunResult {
        await Task.detached(priority: .utility) {
            Self.runSync(
                executable: executable,
                arguments: arguments,
                environment: environment,
                timeout: timeout,
                stdoutLimit: stdoutLimit
            )
        }.value
    }

    private static func runSync(
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: Duration,
        stdoutLimit: Int
    ) -> OrcaCommandRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return OrcaCommandRunResult(
                exitCode: nil, stdout: Data(), stderr: Data(),
                timedOut: false, killed: false, stdoutOverflowed: false
            )
        }

        let stdoutBuffer = OrcaPipeDrain.Buffer(limit: stdoutLimit)
        let stderrBuffer = OrcaPipeDrain.Buffer(limit: OrcaPipeDrain.stderrCap)
        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        // Only this utility worker owns the descriptors. No blocking Foundation reads,
        // no reader queues to abandon, and no close underneath an active reader.
        let descriptors = [stdoutHandle.fileDescriptor, stderrHandle.fileDescriptor]
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }
        guard descriptors.allSatisfy({ fcntl($0, F_SETFL, O_NONBLOCK) != -1 }) else {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            return OrcaCommandRunResult(exitCode: nil, stdout: Data(), stderr: Data(),
                                       timedOut: true, killed: true)
        }
        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()
        let clock = ContinuousClock()
        let origin = clock.now
        var lifecycle = OrcaCommandLifecycle(timeout: timeout)
        var completed = [false, false]
        var drainFailed = false
        let buffers = [stdoutBuffer, stderrBuffer]
        while true {
            for index in 0..<2 where !completed[index] {
                switch OrcaPipeDrain.drain(into: buffers[index], read: {
                    OrcaPipeDrain.readAvailable(descriptors[index])
                }) {
                case .eof: completed[index] = true
                case .failed: completed[index] = true; drainFailed = true
                default: break
                }
            }
            let action = lifecycle.step(elapsed: origin.duration(to: clock.now),
                                        childRunning: process.isRunning,
                                        drainsComplete: completed.allSatisfy { $0 })
            switch action {
            case .terminate: process.terminate()
            case .kill: kill(process.processIdentifier, SIGKILL)
            case let .finish(incomplete): drainFailed = drainFailed || incomplete
            case .wait: break
            }
            if case .finish = action { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()
        let timedOut = lifecycle.timedOut || drainFailed
        let killed = lifecycle.killed

        let (stdout, overflowed) = stdoutBuffer.snapshot()
        let (stderr, _) = stderrBuffer.snapshot()
        if overflowed {
            return OrcaCommandRunResult(
                exitCode: process.isRunning ? nil : process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                timedOut: true,
                killed: killed,
                stdoutOverflowed: true
            )
        }
        return OrcaCommandRunResult(
            exitCode: process.isRunning ? nil : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut,
            killed: killed,
            stdoutOverflowed: false
        )
    }
}

@MainActor
final class OrcaActivitySource: KeepAwakeSource {
    private(set) var report: [KeepAwakeSourceReport] = []
    var onChange: (() -> Void)?

    /// C7-7：由 hub 依行程偵測開關同步；預設 unverified（不虛報已退路）。
    var fallbackCapability: OrcaFallbackCapability = .unverified

    private var enabled = true
    private var countPermissionAsWorking = true
    private var cliPathOverride: String?
    private var running = false
    private var pollTask: Task<Void, Never>?
    /// 目前持有的 in-flight 代號；完成前不清除，確保最多一個子行程（C7-2）。
    private var pendingRefresh = false
    private var activeFlight: UInt64?
    private var nextFlight: UInt64 = 0
    private var generation: UInt64 = 0
    private var consecutiveFailures = 0
    private var lastWorkingAt: Date?
    private var lastClassification: OrcaClassification?
    /// 測試／排程斷言：最近一次非 immediate 排程的間隔。
    private(set) var lastScheduledInterval: Duration?
    private var observerGeneration: UInt64 = 0
    var workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    private var observers: [NSObjectProtocol] = []

    var sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    private let runner: any OrcaCommandRunning
    private let presence: any OrcaPresenceChecking
    private let now: () -> Date
    private let normalInterval: Duration
    private let backoffInterval: Duration
    private let commandTimeout: Duration
    private let graceSeconds: Double
    private let stdoutLimit = 4 * 1_024 * 1_024

    /// 測試縫：覆寫 CLI 解析結果。
    var cliPathResolver: (() -> String?)?
    /// 測試縫：覆寫 presence 檢查（可丟到 utility）。
    var presenceResolver: (() -> Bool)?
    var asyncPresenceResolver: (() async -> Bool)?
    var asyncCLIPathResolver: (() async -> String?)?

    init(
        runner: any OrcaCommandRunning = ProcessOrcaCommandRunner(),
        workspaceCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        presence: any OrcaPresenceChecking = WorkspaceOrcaPresenceChecker(),
        now: @escaping () -> Date = Date.init,
        normalInterval: Duration = .seconds(30),
        backoffInterval: Duration = .seconds(120),
        commandTimeout: Duration = .seconds(5),
        graceSeconds: Double = KeepAwakeBusyAggregator.defaultGraceSeconds
    ) {
        self.runner = runner
        self.workspaceCenter = workspaceCenter
        self.presence = presence
        self.now = now
        self.normalInterval = normalInterval
        self.backoffInterval = backoffInterval
        self.commandTimeout = commandTimeout
        self.graceSeconds = graceSeconds
    }

    func configure(enabled: Bool, countPermissionAsWorking: Bool, cliPathOverride: String?) {
        let changed = self.enabled != enabled
            || self.countPermissionAsWorking != countPermissionAsWorking
            || self.cliPathOverride != cliPathOverride
        self.enabled = enabled
        self.countPermissionAsWorking = countPermissionAsWorking
        self.cliPathOverride = cliPathOverride
        if changed {
            generation &+= 1
        }
    }

    func start() {
        start(schedulePolling: true)
    }

    /// 測試用 `pollOnce` 時傳 `schedulePolling: false`，避免與手動輪詢搶 `activeFlight`。
    func start(schedulePolling: Bool) {
        guard !running else { return }
        running = true
        installWorkspaceObservers()
        if schedulePolling {
            schedulePoll(immediate: true)
        }
    }

    func stop() {
        generation &+= 1
        running = false
        pendingRefresh = false
        pollTask?.cancel()
        pollTask = nil
        removeWorkspaceObservers()
        lastWorkingAt = nil
        lastClassification = nil
        consecutiveFailures = 0
        // 不清除 activeFlight：舊子行程完成後自行釋放，避免雙重 child（C7-2）。
        report = []
    }

    func clearEvidence() {
        generation &+= 1
        lastWorkingAt = nil
        lastClassification = nil
        consecutiveFailures = 0
        report = []
    }

    /// 測試直接呼叫。
    func pollOnce() async {
        await refresh()
    }

    /// 測試：重排下一輪並更新 `lastScheduledInterval`（V-C07-2 退避斷言）。
    func rescheduleForTesting(immediate: Bool) {
        schedulePoll(immediate: immediate)
    }

    /// Hub tick：Orca 不在時推進／清除收工寬限（C7-8）。
    func refreshAbsenceGraceIfNeeded() {
        let gen = generation
        Task { [weak self] in
            guard let self, self.generation == gen else { return }
            await self.reevaluatePresence()
        }
    }

    func reevaluatePresence() async {
        let gen = generation
        guard enabled, running else { return }
        let present = await checkPresence()
        guard generation == gen, enabled, running else { return }
        if !present {
            generation &+= 1 // invalidate any command/preflight that observed presence
            applyAbsence(notify: true)
        }
    }

    private func checkPresence() async -> Bool {
        if let asyncPresenceResolver { return await asyncPresenceResolver() }
        if let presenceResolver { return presenceResolver() }
        return await Task.detached(priority: .utility) { [presence] in
            presence.isOrcaRunning()
        }.value
    }

    // MARK: - Polling

    private func schedulePoll(immediate: Bool) {
        pollTask?.cancel()
        let interval = consecutiveFailures >= 3 ? backoffInterval : normalInterval
        lastScheduledInterval = immediate ? .zero : interval
        pollTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            if !immediate {
                try? await self?.sleep(interval)
            }
            guard let self, !Task.isCancelled, self.running else { return }
            await self.refresh()
            guard self.running, !Task.isCancelled else { return }
            self.schedulePoll(immediate: false)
        }
    }

    private func refresh() async {
        let gen = generation
        guard enabled, running, activeFlight == nil else { return }

        nextFlight &+= 1
        let flight = nextFlight
        activeFlight = flight
        defer {
            if activeFlight == flight { activeFlight = nil }
            if pendingRefresh, running, enabled {
                pendingRefresh = false
                schedulePoll(immediate: true)
            }
        }

        let present = await checkPresence()
        guard generation == gen, enabled, running, !Task.isCancelled else { return }

        guard present else {
            applyAbsence(notify: true)
            return
        }

        let cli: String?
        if let asyncCLIPathResolver {
            cli = await asyncCLIPathResolver()
        } else if let cliPathResolver {
            cli = cliPathResolver()
        } else {
            cli = await Task.detached(priority: .utility) { [cliPathOverride] in
                OrcaCLILocator.resolve(override: cliPathOverride)
            }.value
        }
        guard generation == gen, enabled, running, !Task.isCancelled else { return }

        guard let cli else {
            publish(
                KeepAwakeSourceReport(
                    id: "orca",
                    kind: .orca,
                    displayName: "Orca",
                    detail: nil,
                    isWorkingNow: false,
                    lastWorkingAt: lastWorkingAt,
                    health: .unavailable(reason: "找不到 orca CLI")
                )
            )
            return
        }

        let result = await runner.run(
            executable: cli,
            arguments: ["worktree", "ps", "--json"],
            environment: [
                "PATH": OrcaCLILocator.defaultPATH,
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            ],
            timeout: commandTimeout,
            stdoutLimit: stdoutLimit
        )

        guard generation == gen, enabled, running, !Task.isCancelled else { return }

        let stillPresent = await checkPresence()
        guard generation == gen, enabled, running, !Task.isCancelled else { return }
        guard stillPresent else { applyAbsence(notify: true); return }

        if result.stdoutOverflowed || result.timedOut || result.killed {
            consecutiveFailures += 1
            publishFailed(reason: result.stdoutOverflowed ? "stdout 超過上限" : "逾時")
            return
        }

        guard let code = result.exitCode, code == 0,
              let text = String(data: result.stdout, encoding: .utf8)
        else {
            consecutiveFailures += 1
            publishFailed(reason: "CLI 失敗")
            return
        }

        let classification = OrcaActivityPlanner.classifyJSON(
            text,
            countPermissionAsWorking: countPermissionAsWorking
        )
        lastClassification = classification
        applyClassification(classification)
    }

    private func applyClassification(_ classification: OrcaClassification) {
        let instant = now()
        switch classification {
        case let .working(rows, qualityWarning):
            consecutiveFailures = 0
            lastWorkingAt = instant
            let workingCount = rows.filter { $0.status == .working }.count
            let permissionCount = rows.filter { $0.status == .permission }.count
            var parts: [String] = []
            if workingCount > 0 { parts.append("\(workingCount) 個 worktree working") }
            if permissionCount > 0 { parts.append("\(permissionCount) 個等待權限") }
            let health: KeepAwakeSourceHealth
            if let qualityWarning {
                health = .degraded(reason: qualityWarning)
            } else {
                health = .ok
            }
            publish(
                KeepAwakeSourceReport(
                    id: "orca",
                    kind: .orca,
                    displayName: "Orca",
                    detail: parts.joined(separator: "、"),
                    isWorkingNow: true,
                    lastWorkingAt: instant,
                    health: health
                )
            )
        case .idle:
            consecutiveFailures = 0
            publishIdleKeepingGrace(health: .ok)
        case let .incomplete(reason):
            consecutiveFailures = 0
            publish(
                KeepAwakeSourceReport(
                    id: "orca",
                    kind: .orca,
                    displayName: "Orca",
                    detail: reason,
                    isWorkingNow: false,
                    lastWorkingAt: lastWorkingAt,
                    health: .degraded(reason: reason)
                )
            )
        case let .failed(reason):
            consecutiveFailures += 1
            publishFailed(reason: reason)
        }
    }

    private func applyAbsence(notify: Bool) {
        // 工作中立刻收工：結束時刻記一次，不反覆延長（C7-8）。
        if report.contains(where: \.isWorkingNow) {
            lastWorkingAt = now()
        }
        let previous = report
        if let last = lastWorkingAt {
            let age = now().timeIntervalSince(last)
            if age < graceSeconds {
                report = [
                    KeepAwakeSourceReport(
                        id: "orca",
                        kind: .orca,
                        displayName: "Orca",
                        detail: nil,
                        isWorkingNow: false,
                        lastWorkingAt: last,
                        health: .ok
                    ),
                ]
            } else {
                lastWorkingAt = nil
                report = []
            }
        } else {
            report = []
        }
        if notify, previous != report {
            onChange?()
        }
    }

    private func publishFailed(reason: String) {
        let message: String
        switch fallbackCapability {
        case .active:
            message = "Orca CLI 失敗：\(reason)，改用行程偵測"
        case .unverified, .unavailable:
            // C7-7：不虛報退路已生效／已驗證。
            message = "Orca CLI 失敗：\(reason)"
        }
        publish(
            KeepAwakeSourceReport(
                id: "orca",
                kind: .orca,
                displayName: "Orca",
                detail: nil,
                isWorkingNow: false,
                lastWorkingAt: lastWorkingAt,
                health: .degraded(reason: message)
            )
        )
    }

    private func publishIdleKeepingGrace(health: KeepAwakeSourceHealth) {
        publish(
            KeepAwakeSourceReport(
                id: "orca",
                kind: .orca,
                displayName: "Orca",
                detail: nil,
                isWorkingNow: false,
                lastWorkingAt: lastWorkingAt,
                health: health
            )
        )
    }

    private func publish(_ next: KeepAwakeSourceReport) {
        let previous = report
        report = [next]
        if previous != report {
            onChange?()
        }
    }

    // MARK: - Workspace observers (C7-8)

    private func installWorkspaceObservers() {
        removeWorkspaceObservers()
        observerGeneration &+= 1
        let handler = workspaceEventHandler()
        let center = workspaceCenter
        let launch = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in _ = handler() }
        let terminate = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in _ = handler() }
        observers = [launch, terminate]
    }

    /// The queued callback carries the observer lifecycle, not the lifecycle at delivery.
    func workspaceEventHandler() -> @Sendable () -> Task<Void, Never> {
        let lifecycle = observerGeneration
        return { [weak self] in
            Task { @MainActor in self?.handleWorkspaceChange(lifecycle: lifecycle) }
        }
    }

    private func removeWorkspaceObservers() {
        observerGeneration &+= 1
        for observer in observers {
            workspaceCenter.removeObserver(observer)
        }
        observers = []
    }

    private func handleWorkspaceChange(lifecycle: UInt64) {
        guard observerGeneration == lifecycle, running, enabled else { return }
        generation &+= 1
        pendingRefresh = activeFlight != nil
        Task { [weak self] in
            guard let self, self.observerGeneration == lifecycle else { return }
            await self.reevaluatePresence()
        }
        // 啟動／結束立即重評；取消退避睡眠（C7-8）。
        schedulePoll(immediate: true)
    }
}
