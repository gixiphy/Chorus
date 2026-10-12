import ChorusCore
import Foundation
import Darwin

/// Fixed-argv `pmset` runner (spec §6.3 / §11.2). No shell; empty environment.
///
/// Callers must never invoke this against a real system from automated tests.
/// Production wiring uses `/usr/bin/pmset`; tests inject `PMSetRunning`.
///
/// I/O must run off the helper ledger queue (V-C05-2 / W1-1). Deadlines use
/// monotonic continuous time so wall-clock jumps cannot extend waits (W1-10).
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
    static let termGraceSeconds: TimeInterval = 1
    /// Extra bound for draining pipes after kill (descendant-held writers).
    static let drainGraceSeconds: TimeInterval = 0.5

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

    /// Drain stdout/stderr with caps; TERM then KILL process group; always reap with bounded drain.
    /// Deadlines are monotonic (`MonotonicTime`) — wall-clock changes cannot extend waits.
    /// Descendant-held pipe writers cannot wedge forever: we kill the group and time-box drain (W1-1).
    static func runSubprocess(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> (exitCode: Int32, stdout: Data, stderr: Data, truncated: Bool) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = [:]
        // Own process group so descendants sharing the pipes can be killed.
        process.qualityOfService = .userInitiated

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let stdoutBox = OutputBox(limit: maxOutputBytes)
        let stderrBox = OutputBox(limit: maxOutputBytes)
        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor
        guard fcntl(outFD, F_SETFL, O_NONBLOCK) == 0,
              fcntl(errFD, F_SETFL, O_NONBLOCK) == 0 else {
            throw PMSetRunnerError.launchFailed
        }

        do {
            try process.launch()
        } catch {
            throw PMSetRunnerError.launchFailed
        }

        try? stdoutPipe.fileHandleForWriting.close()
        try? stderrPipe.fileHandleForWriting.close()

        // Put child in its own process group (best-effort; race if already exited).
        let pid = process.processIdentifier
        if pid > 0 {
            _ = setpgid(pid, pid)
        }

        let deadline = MonotonicTime.seconds() + timeout
        while process.isRunning, MonotonicTime.seconds() < deadline {
            drainAvailable(fd: outFD, box: stdoutBox)
            drainAvailable(fd: errFD, box: stderrBox)
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            process.terminate() // SIGTERM to direct child
            if pid > 0 {
                kill(-pid, SIGTERM)
            }
            let termDeadline = MonotonicTime.seconds() + termGraceSeconds
            while process.isRunning, MonotonicTime.seconds() < termDeadline {
                drainAvailable(fd: outFD, box: stdoutBox)
                drainAvailable(fd: errFD, box: stderrBox)
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                if pid > 0 {
                    kill(-pid, SIGKILL)
                }
                kill(pid, SIGKILL)
            }
            boundedReapAndDrain(
                process: process,
                stdoutPipe: stdoutPipe,
                stderrPipe: stderrPipe,
                stdoutBox: stdoutBox,
                stderrBox: stderrBox
            )
            throw PMSetRunnerError.timedOut
        }

        boundedReapAndDrain(
            process: process,
            stdoutPipe: stdoutPipe,
            stderrPipe: stderrPipe,
            stdoutBox: stdoutBox,
            stderrBox: stderrBox
        )

        return (
            exitCode: process.terminationStatus,
            stdout: stdoutBox.data,
            stderr: stderrBox.data,
            truncated: stdoutBox.truncated || stderrBox.truncated
        )
    }

    /// Time-boxed reap + pipe drain — never unbounded `readDataToEndOfFile` / `waitUntilExit` (W1-1).
    private static func boundedReapAndDrain(
        process: Process,
        stdoutPipe: Pipe,
        stderrPipe: Pipe,
        stdoutBox: OutputBox,
        stderrBox: OutputBox
    ) {
        let reapDeadline = MonotonicTime.seconds() + drainGraceSeconds + termGraceSeconds
        while process.isRunning, MonotonicTime.seconds() < reapDeadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning {
            let pid = process.processIdentifier
            if pid > 0 {
                kill(-pid, SIGKILL)
                kill(pid, SIGKILL)
            }
        }

        // Foundation owns child reaping. Never create an indefinitely waiting reap thread.
        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor
        var outEOF = false
        var errEOF = false
        let drainDeadline = MonotonicTime.seconds() + drainGraceSeconds
        repeat {
            outEOF = drainAvailable(fd: outFD, box: stdoutBox) || outEOF
            errEOF = drainAvailable(fd: errFD, box: stderrBox) || errEOF
            if outEOF && errEOF { break }
            Thread.sleep(forTimeInterval: 0.01)
        } while MonotonicTime.seconds() < drainDeadline
        if !outEOF { stdoutBox.markTruncated() }
        if !errEOF { stderrBox.markTruncated() }
    }

    /// Fixed-size nonblocking reads, with a per-call byte budget so an endless writer
    /// cannot keep us inside drain beyond the subprocess deadline.
    @discardableResult
    private static func drainAvailable(fd: Int32, box: OutputBox) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        for _ in 0..<16 {
            let count = read(fd, &buffer, buffer.count)
            if count == 0 { return true }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { box.markTruncated() }
                return false
            }
            box.append(Data(buffer.prefix(count)))
        }
        return false
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

    func markTruncated() {
        lock.lock(); defer { lock.unlock() }; truncated = true
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
