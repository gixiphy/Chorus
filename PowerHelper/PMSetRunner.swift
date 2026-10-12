import ChorusCore
import Foundation

/// Fixed-argv `pmset` runner (spec §6.3 / §11.2). No shell; empty environment.
///
/// Callers must never invoke this against a real system from automated tests.
/// Production wiring uses `/usr/bin/pmset`; tests inject `PMSetRunning`.
protocol PMSetRunning: AnyObject, Sendable {
    func readSleepDisabled() throws -> Bool?
    func writeSleepDisabled(_ enabled: Bool) throws
}

enum PMSetRunnerError: Error, Equatable {
    case launchFailed
    case timedOut
    case nonZeroExit(Int32)
    case truncatedOutput
    case unparseableOutput
    case writeNotConfirmed
}

/// Assembles argv only — exposed for unit tests (C05).
enum PMSetArgumentBuilder {
    static let executablePath = "/usr/bin/pmset"

    /// Write: `pmset -a disablesleep 0|1`
    static func writeArguments(enabled: Bool) -> [String] {
        ["-a", "disablesleep", enabled ? "1" : "0"]
    }

    /// Read: `pmset -g`
    static func readArguments() -> [String] {
        ["-g"]
    }
}

final class PMSetRunner: PMSetRunning, @unchecked Sendable {
    static let defaultTimeout: TimeInterval = 5
    /// Cap stdout/stderr so a wedged pmset cannot fill memory (§14.1).
    static let maxOutputBytes = 256 * 1024

    private let executableURL: URL
    private let timeout: TimeInterval
    private let runProcess: (URL, [String], TimeInterval) throws -> (exitCode: Int32, stdout: Data, stderr: Data, truncated: Bool)

    init(
        executableURL: URL = URL(fileURLWithPath: PMSetArgumentBuilder.executablePath),
        timeout: TimeInterval = PMSetRunner.defaultTimeout,
        runProcess: @escaping (URL, [String], TimeInterval) throws -> (exitCode: Int32, stdout: Data, stderr: Data, truncated: Bool) = PMSetRunner.runSubprocess
    ) {
        self.executableURL = executableURL
        self.timeout = timeout
        self.runProcess = runProcess
    }

    func readSleepDisabled() throws -> Bool? {
        let result = try runProcess(executableURL, PMSetArgumentBuilder.readArguments(), timeout)
        guard result.exitCode == 0 else { throw PMSetRunnerError.nonZeroExit(result.exitCode) }
        guard !result.truncated else { throw PMSetRunnerError.truncatedOutput }
        guard let text = String(data: result.stdout, encoding: .utf8) else {
            throw PMSetRunnerError.unparseableOutput
        }
        // Gate: only parse after exit=0 and non-truncated (C03 handoff / §14.1).
        guard let value = PMSetOutputParser.sleepDisabled(fromPMSetG: text) else {
            throw PMSetRunnerError.unparseableOutput
        }
        return value
    }

    func writeSleepDisabled(_ enabled: Bool) throws {
        let write = try runProcess(executableURL, PMSetArgumentBuilder.writeArguments(enabled: enabled), timeout)
        guard write.exitCode == 0 else { throw PMSetRunnerError.nonZeroExit(write.exitCode) }
        guard !write.truncated else { throw PMSetRunnerError.truncatedOutput }

        // Write-then-readback confirmation (spec §6.3).
        let confirmed = try readSleepDisabled()
        guard confirmed == enabled else { throw PMSetRunnerError.writeNotConfirmed }
    }

    /// Drain stdout/stderr with caps; TERM then KILL; always reap. Must not run on the
    /// helper's ledger serial queue (watchdog stays responsive — §14.1 / V-C05-2).
    static func runSubprocess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> (exitCode: Int32, stdout: Data, stderr: Data, truncated: Bool) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = [:]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdoutBox = OutputBox(limit: maxOutputBytes)
        let stderrBox = OutputBox(limit: maxOutputBytes)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            stdoutBox.append(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            stderrBox.append(handle.availableData)
        }

        do {
            try process.launch()
        } catch {
            throw PMSetRunnerError.launchFailed
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate() // SIGTERM
            let termDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < termDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw PMSetRunnerError.timedOut
        }

        process.waitUntilExit()
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        // Drain any remaining bytes.
        stdoutBox.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
        stderrBox.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())

        return (
            exitCode: process.terminationStatus,
            stdout: stdoutBox.data,
            stderr: stderrBox.data,
            truncated: stdoutBox.truncated || stderrBox.truncated
        )
    }
}

private final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private(set) var data = Data()
    private(set) var truncated = false

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        if data.count >= limit {
            truncated = true
            return
        }
        let remaining = limit - data.count
        if chunk.count > remaining {
            data.append(chunk.prefix(remaining))
            truncated = true
        } else {
            data.append(chunk)
        }
    }
}
