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
        // 退路：comm == "Orca"（不需 argv）。
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

/// 真實子行程 runner：5 秒逾時、SIGTERM→1s→SIGKILL、stdout 上限 4 MB。
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
                exitCode: nil, stdout: Data(), stderr: Data(), timedOut: false, killed: false
            )
        }

        let seconds = Double(timeout.components.seconds)
            + Double(timeout.components.attoseconds) / 1e18
        let deadline = Date().addingTimeInterval(seconds)
        var timedOut = false
        var killed = false

        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            timedOut = true
            process.terminate() // SIGTERM
            let killDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                killed = true
                process.interrupt()
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        var stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = Data(stderrPipe.fileHandleForReading.readDataToEndOfFile().prefix(2_048))
        if stdout.count > stdoutLimit {
            stdout = Data(stdout.prefix(stdoutLimit))
            return OrcaCommandRunResult(
                exitCode: process.terminationStatus,
                stdout: stdout,
                stderr: stderr,
                timedOut: true,
                killed: killed
            )
        }
        return OrcaCommandRunResult(
            exitCode: process.isRunning ? nil : process.terminationStatus,
            stdout: stdout,
            stderr: stderr,
            timedOut: timedOut,
            killed: killed
        )
    }
}

@MainActor
final class OrcaActivitySource: KeepAwakeSource {
    private(set) var report: [KeepAwakeSourceReport] = []
    var onChange: (() -> Void)?

    private var enabled = true
    private var countPermissionAsWorking = true
    private var cliPathOverride: String?
    private var running = false
    private var pollTask: Task<Void, Never>?
    private var inFlight = false
    private var consecutiveFailures = 0
    private var lastWorkingAt: Date?
    private var lastClassification: OrcaClassification?

    private let runner: any OrcaCommandRunning
    private let presence: any OrcaPresenceChecking
    private let now: () -> Date
    private let normalInterval: Duration
    private let backoffInterval: Duration
    private let commandTimeout: Duration
    private let stdoutLimit = 4 * 1_024 * 1_024

    /// 測試縫：覆寫 CLI 解析結果。
    var cliPathResolver: (() -> String?)?

    init(
        runner: any OrcaCommandRunning = ProcessOrcaCommandRunner(),
        presence: any OrcaPresenceChecking = WorkspaceOrcaPresenceChecker(),
        now: @escaping () -> Date = Date.init,
        normalInterval: Duration = .seconds(30),
        backoffInterval: Duration = .seconds(120),
        commandTimeout: Duration = .seconds(5)
    ) {
        self.runner = runner
        self.presence = presence
        self.now = now
        self.normalInterval = normalInterval
        self.backoffInterval = backoffInterval
        self.commandTimeout = commandTimeout
    }

    func configure(enabled: Bool, countPermissionAsWorking: Bool, cliPathOverride: String?) {
        self.enabled = enabled
        self.countPermissionAsWorking = countPermissionAsWorking
        self.cliPathOverride = cliPathOverride
    }

    func start() {
        guard !running else { return }
        running = true
        schedulePoll(immediate: true)
    }

    func stop() {
        running = false
        pollTask?.cancel()
        pollTask = nil
        inFlight = false
        report = []
    }

    func clearEvidence() {
        lastWorkingAt = nil
        lastClassification = nil
        consecutiveFailures = 0
        report = []
    }

    /// 測試直接呼叫。
    func pollOnce() async {
        await refresh()
    }

    // MARK: - Polling

    private func schedulePoll(immediate: Bool) {
        pollTask?.cancel()
        let interval = consecutiveFailures >= 3 ? backoffInterval : normalInterval
        pollTask = Task { [weak self] in
            if !immediate {
                try? await Task.sleep(for: interval)
            }
            guard let self, !Task.isCancelled, self.running else { return }
            await self.refresh()
            guard self.running, !Task.isCancelled else { return }
            self.schedulePoll(immediate: false)
        }
    }

    private func refresh() async {
        guard enabled, running, !inFlight else { return }
        guard presence.isOrcaRunning() else {
            // 偵測不到 Orca：停止輪詢雜訊，保留一次收工寬限（V-C07-5）。
            if lastWorkingAt != nil || report.contains(where: \.isWorkingNow) {
                publishIdleKeepingGrace(health: .ok)
            } else {
                report = []
            }
            return
        }

        // 測試縫：一旦注入 resolver，其 nil 也代表「找不到」，不得回退本機定位。
        let cli: String?
        if let cliPathResolver {
            cli = cliPathResolver()
        } else {
            cli = OrcaCLILocator.resolve(override: cliPathOverride)
        }
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

        inFlight = true
        defer { inFlight = false }

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

        if result.timedOut || result.killed {
            consecutiveFailures += 1
            publishFailed(reason: "逾時")
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
        case let .working(rows):
            consecutiveFailures = 0
            lastWorkingAt = instant
            let workingCount = rows.filter { $0.status == .working }.count
            let permissionCount = rows.filter { $0.status == .permission }.count
            var parts: [String] = []
            if workingCount > 0 { parts.append("\(workingCount) 個 worktree working") }
            if permissionCount > 0 { parts.append("\(permissionCount) 個等待權限") }
            publish(
                KeepAwakeSourceReport(
                    id: "orca",
                    kind: .orca,
                    displayName: "Orca",
                    detail: parts.joined(separator: "、"),
                    isWorkingNow: true,
                    lastWorkingAt: instant,
                    health: .ok
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

    private func publishFailed(reason: String) {
        publish(
            KeepAwakeSourceReport(
                id: "orca",
                kind: .orca,
                displayName: "Orca",
                detail: nil,
                isWorkingNow: false,
                lastWorkingAt: lastWorkingAt,
                health: .degraded(reason: "Orca CLI 失敗：\(reason)，改用行程偵測")
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
}
