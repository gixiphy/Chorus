import ChorusCore
import Foundation

/// 子行程執行工具：pipe I/O、環境白名單注入、逾時終止、取消終止。
/// claude 類 CLI 的 `-p` 模式對非 TTY 正常；PTY 包裝等接入層 E1（agy）再引入。
enum CLIProcessRunner {
    struct Output: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// 白名單環境；PATH 前置執行檔目錄，讓 CLI 找得到自帶 runtime。
    /// USER 必要：claude CLI 靠它查 Keychain 憑證，缺了會誤報「未登入」。
    static func whitelistedEnvironment(executableDirectory: String) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let basePath = inherited["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        var environment = [
            "PATH": "\(executableDirectory):\(basePath):/opt/homebrew/bin:/usr/local/bin",
            "HOME": inherited["HOME"] ?? NSHomeDirectory(),
            "TERM": inherited["TERM"] ?? "xterm-256color",
            "USER": inherited["USER"] ?? NSUserName(),
            "LOGNAME": inherited["LOGNAME"] ?? NSUserName(),
        ]
        if let tmpdir = inherited["TMPDIR"] { environment["TMPDIR"] = tmpdir }
        return environment
    }

    /// 執行到結束；逾時或取消都 terminate 子行程。
    /// stdout/stderr 在獨立執行緒並行讀取，避免管線塞滿造成死鎖。
    static func run(
        executable: URL,
        arguments: [String],
        stdin stdinText: String?,
        timeout: Duration
    ) async throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = whitelistedEnvironment(
            executableDirectory: executable.deletingLastPathComponent().path
        )

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let stdinPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = stdinPipe

        let flags = Flags()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // handler 先於 run() 設定，保證必被呼叫
                process.terminationHandler = { _ in
                    if flags.claimResume() { continuation.resume() }
                }
                do {
                    try process.run()
                } catch {
                    if flags.claimResume() { continuation.resume(throwing: error) }
                    return
                }

                if let stdinText {
                    let handle = stdinPipe.fileHandleForWriting
                    Thread.detachNewThread {
                        try? handle.write(contentsOf: Data(stdinText.utf8))
                        try? handle.close()
                    }
                } else {
                    try? stdinPipe.fileHandleForWriting.close()
                }

                // 逾時 watchdog：時限到還在跑就 terminate（terminationHandler 負責 resume）
                let seconds = Double(timeout.components.seconds)
                    + Double(timeout.components.attoseconds) / 1e18
                Thread.detachNewThread {
                    let deadline = Date().addingTimeInterval(seconds)
                    while process.isRunning, Date() < deadline {
                        Thread.sleep(forTimeInterval: 0.1)
                    }
                    if process.isRunning {
                        flags.markTimedOut()
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        let stdout = await readToEnd(stdoutPipe.fileHandleForReading)
        let stderr = await readToEnd(stderrPipe.fileHandleForReading)

        try Task.checkCancellation()
        if flags.timedOut { throw AdviceError.timedOut }
        return Output(
            status: process.terminationStatus,
            stdout: String(data: stdout, encoding: .utf8) ?? "",
            stderr: String(data: stderr, encoding: .utf8) ?? ""
        )
    }

    private static func readToEnd(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                let data = (try? handle.readToEnd()) ?? Data()
                continuation.resume(returning: data)
            }
        }
    }

    /// 一次性 resume 與逾時標記（terminationHandler / run 失敗 / watchdog 之間共享）。
    private final class Flags: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var didTimeOut = false

        func claimResume() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }

        func markTimedOut() {
            lock.lock(); defer { lock.unlock() }
            didTimeOut = true
        }

        var timedOut: Bool {
            lock.lock(); defer { lock.unlock() }
            return didTimeOut
        }
    }
}

/// 正式引擎：橋接本機已登入的 LLM CLI（零金鑰、零憑證經手）。
/// 呼叫（單發）→ envelope/stdout 解析 → 失敗重試一次 → 型別化錯誤。
/// `sanitized(for:)` 由 LightingAdvisor 統一把關，這裡只回未清洗的 advice。
struct CLIAdviceProvider: LightingAdviceProvider {
    let engine: KnownCLIEngine
    let executable: URL
    var timeout: Duration = .seconds(120)

    func advise(photoPaths: [String], context: AdviceContext) async throws -> LightingAdvice {
        let basePrompt = AdvicePrompt.cliPrompt(
            context: context,
            photoPaths: photoPaths,
            readInstruction: engine.readInstruction
        )
        do {
            return try await attempt(prompt: basePrompt)
        } catch let error as AdviceDecodeError {
            // CLI 自報的執行錯誤（如未認證）重試也不會好，直接映射
            if case let .cliReportedError(message) = error {
                throw Self.mapReportedError(engineID: engine.id, message: message)
            }
            // 其餘 decode 失敗自動重試一次，prompt 附上修正指示
            do {
                return try await attempt(prompt: basePrompt + "\n\n" + AdvicePrompt.retryInstruction)
            } catch let retryError as AdviceDecodeError {
                throw AdviceError.decodeFailed(raw: Self.rawText(from: retryError))
            }
        }
    }

    private static func mapReportedError(engineID: String, message: String) -> AdviceError {
        if authMarkers.contains(where: message.lowercased().contains) {
            return .notLoggedIn(engineID: engineID)
        }
        return .processFailed(status: 0, stderr: sanitizedStderr(message))
    }

    private func attempt(prompt: String) async throws -> LightingAdvice {
        let invocation = engine.invocation(prompt: prompt)
        let output: CLIProcessRunner.Output
        do {
            output = try await CLIProcessRunner.run(
                executable: executable,
                arguments: invocation.arguments,
                stdin: invocation.stdin,
                timeout: timeout
            )
        } catch let error as AdviceError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AdviceError.engineNotFound(engineID: engine.id)
        }

        guard output.status == 0 else {
            throw Self.mapNonZeroExit(engineID: engine.id, output: output)
        }
        return try AdviceCodec.decode(stdout: output.stdout, codec: engine.codec)
    }

    private static let authMarkers = [
        "not logged in", "login", "log in", "authentication", "authenticate",
        "unauthorized", "oauth", "revoked", "401", "api key", "credential",
    ]

    /// 非零退出：stderr／stdout 含認證字樣 → 未登入；其餘帶錯誤摘要。
    /// claude `--output-format json` 出錯時 stderr 是空的、訊息在 stdout 的
    /// envelope `result` 欄位，stderr 空白時退回從 stdout 取。
    private static func mapNonZeroExit(engineID: String, output: Output) -> AdviceError {
        let combined = (output.stderr + "\n" + output.stdout).lowercased()
        if authMarkers.contains(where: combined.contains) {
            return .notLoggedIn(engineID: engineID)
        }
        var message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty {
            message = envelopeResultText(from: output.stdout)
                ?? output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return .processFailed(status: output.status, stderr: sanitizedStderr(message))
    }

    private static func envelopeResultText(from stdout: String) -> String? {
        guard let data = stdout.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["result"] as? String
    }

    /// stderr 入 UI／log 前過濾疑似 token 字樣（安全紀律 §5）。
    private static func sanitizedStderr(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(sk-[A-Za-z0-9-_]{8,}|Bearer\s+\S+|eyJ[A-Za-z0-9-_.]{16,})"#,
            with: "[已遮蔽]",
            options: .regularExpression
        )
    }

    private static func rawText(from error: AdviceDecodeError) -> String {
        switch error {
        case .emptyOutput: ""
        case let .envelopeParseFailed(raw): raw
        case let .cliReportedError(message): message
        case let .adviceParseFailed(raw): raw
        }
    }

    typealias Output = CLIProcessRunner.Output
}
