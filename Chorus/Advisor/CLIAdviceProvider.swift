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

    /// SIGTERM 之後多久補一刀 SIGKILL。
    ///
    /// `Process.terminate()` 只送 SIGTERM，CLI 大可以不理：2026-09-04 實測 agy 卡在
    /// 等模型回應（0% CPU、兩條對外連線掛著），SIGTERM 完全沒作用——逾時與「取消」
    /// 都變成空包彈，`terminationHandler` 不會來，我們這邊的 continuation 永遠不 resume，
    /// 畫面就一直停在「翻譯中 0/587」，行程還一個 150MB 地留著。SIGKILL 擋不掉。
    static let killGrace: TimeInterval = 3

    /// 答案印完之後，還願意等行程自己收尾多久。
    /// 正常的 CLI 印完就退，**退出碼與 stderr 還有用**（非零退出要照原本的路徑
    /// 報錯），所以不能一看到完整輸出就把行程砍掉當成功。等過這段還賴著的
    /// （agy）才提前收工。
    static let lingerGrace: TimeInterval = 2

    /// 還活著的子行程 pid：App 結束時一次收乾淨，不留孤兒（會被 launchd 收養、
    /// 賴在那裡吃記憶體）。
    private static let liveProcesses = LiveProcesses()

    /// 送 SIGTERM，寬限期過了還在就 SIGKILL。
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: killGrace)
            // isRunning 為真才動手：行程收掉後 pid 會被系統回收再利用
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
    }

    /// App 結束前呼叫：手上還在跑的 CLI 一律 SIGKILL。
    /// 沒人接手的話它們會活到自己想結束為止（見 `killGrace` 的註解）。
    static func killAll() {
        for pid in liveProcesses.pids { kill(pid, SIGKILL) }
    }

    /// 邊跑邊收的輸出緩衝：讀到一塊就交給 `onChunk` 判斷「答案是不是已經完整」。
    ///
    /// 需要邊讀邊判斷，是因為有的 CLI **把答案印完之後就是不結束**：2026-09-04 實測
    /// agy 43 秒印完整包 JSON，行程再掛 100 秒以上都不退。等行程結束才讀的話，
    /// 到手的答案會被逾時丟掉。
    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var done = false

        var text: String {
            lock.lock(); defer { lock.unlock() }
            return String(decoding: data, as: UTF8.self)
        }

        var isDone: Bool {
            lock.lock(); defer { lock.unlock() }
            return done
        }

        func start(_ handle: FileHandle, onChunk: (@Sendable (String) -> Void)? = nil) {
            Thread.detachNewThread { [self] in
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    lock.lock()
                    data.append(chunk)
                    let snapshot = onChunk == nil ? "" : String(decoding: data, as: UTF8.self)
                    lock.unlock()
                    onChunk?(snapshot)
                }
                lock.lock()
                done = true
                lock.unlock()
            }
        }
    }

    /// pid 清單（多執行緒共用：watchdog、terminationHandler、主執行緒都會碰）。
    private final class LiveProcesses: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: Set<pid_t> = []

        var pids: [pid_t] {
            lock.lock(); defer { lock.unlock() }
            return Array(storage)
        }

        func insert(_ pid: pid_t) { lock.lock(); storage.insert(pid); lock.unlock() }
        func remove(_ pid: pid_t) { lock.lock(); storage.remove(pid); lock.unlock() }
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
    ///
    /// `isComplete` 給的是「這段 stdout 已經是完整答案了」的判斷。成立時就不再等
    /// 行程結束——印完答案賴著不走的 CLI（agy）不該把整批翻譯拖到逾時。
    /// 沒有結束標記的輸出格式（codex 的 plainStdout）傳 nil，維持等到行程結束。
    static func run(
        executable: URL,
        arguments: [String],
        stdin stdinText: String?,
        timeout: Duration,
        isComplete: (@Sendable (String) -> Bool)? = nil
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
        let stdoutCollector = OutputCollector()
        let stderrCollector = OutputCollector()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // handler 先於 run() 設定，保證必被呼叫
                process.terminationHandler = { finished in
                    liveProcesses.remove(finished.processIdentifier)
                    if flags.claimResume() { continuation.resume() }
                }
                do {
                    try process.run()
                    liveProcesses.insert(process.processIdentifier)
                } catch {
                    if flags.claimResume() { continuation.resume(throwing: error) }
                    return
                }

                stderrCollector.start(stderrPipe.fileHandleForReading)
                stdoutCollector.start(stdoutPipe.fileHandleForReading) { snapshot in
                    // 每讀到一塊都會問一次，只有第一次判定完整的那次要起計時器
                    guard let isComplete, isComplete(snapshot), flags.claimOutputComplete() else { return }
                    Thread.detachNewThread {
                        Thread.sleep(forTimeInterval: lingerGrace)
                        // 這段時間內自己退掉的話 terminationHandler 已經接手了
                        if flags.claimResume() {
                            flags.markCompletedEarly()
                            stop(process)
                            continuation.resume()
                        }
                    }
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
                        stop(process)
                    }
                }
            }
        } onCancel: {
            stop(process)
        }

        // 行程正常結束才等收尾（有上限：孫行程可能還抓著管線不放）
        if !flags.completedEarly {
            await waitForCollectors(stdoutCollector, stderrCollector)
        }

        try Task.checkCancellation()
        if flags.timedOut { throw AdviceError.timedOut }
        return Output(
            // 提前收工時行程還沒退，terminationStatus 不能用；答案已經完整，當成功
            status: flags.completedEarly ? 0 : process.terminationStatus,
            stdout: stdoutCollector.text,
            stderr: stderrCollector.text
        )
    }

    /// 等 reader 執行緒讀到 EOF，最多等 `collectorGrace` 秒。
    private static let collectorGrace: TimeInterval = 5

    private static func waitForCollectors(_ collectors: OutputCollector...) async {
        let deadline = Date().addingTimeInterval(collectorGrace)
        while Date() < deadline, collectors.contains(where: { !$0.isDone }) {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// 一次性 resume 與逾時／提前收工標記（terminationHandler / run 失敗 /
    /// watchdog / stdout reader 之間共享）。
    private final class Flags: @unchecked Sendable {
        private let lock = NSLock()
        private var resumed = false
        private var didTimeOut = false
        private var didCompleteEarly = false
        private var outputComplete = false

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

        /// 只讓第一次判定「輸出已完整」的呼叫起計時器。
        func claimOutputComplete() -> Bool {
            lock.lock(); defer { lock.unlock() }
            if outputComplete { return false }
            outputComplete = true
            return true
        }

        func markCompletedEarly() {
            lock.lock(); defer { lock.unlock() }
            didCompleteEarly = true
        }

        var completedEarly: Bool {
            lock.lock(); defer { lock.unlock() }
            return didCompleteEarly
        }
    }
}

/// 正式引擎：橋接本機已登入的 LLM CLI（零金鑰、零憑證經手）。
/// 呼叫（單發）→ envelope/stdout 解析 → 失敗重試一次 → 型別化錯誤。
/// `sanitized(for:)` 由 LightingAdvisor 統一把關，這裡只回未清洗的 advice。
struct CLIAdviceProvider: LightingAdviceProvider {
    let engine: KnownCLIEngine
    let executable: URL
    /// 使用者選定的模型 slug（支援 `--model` 的引擎才用）。
    var model: String?
    var timeout: Duration = .seconds(120)

    func advise(
        photos: [LabeledPhoto],
        context: AdviceContext,
        sandbox: URL?
    ) async throws -> LightingAdvice {
        let basePrompt = AdvicePrompt.cliPrompt(
            context: context,
            photos: photos,
            readInstruction: engine.readInstruction,
            delivery: engine.photoDelivery
        )
        // schema 檔寫進沙箱：與縮圖同一個授權範圍，也隨沙箱一起清掉
        let run = KnownCLIEngine.RunContext(
            sandbox: sandbox,
            schemaFile: CLIAdviceExecution.writeSchema(
                AdvicePrompt.toolInputSchemaJSON(), into: sandbox
            ),
            model: engine.supportsModelSelection ? model : nil,
            photoPaths: photos.map(\.path),
            timeout: timeout
        )
        return try await CLIAdviceExecution.perform(
            engine: engine, executable: executable,
            basePrompt: basePrompt, run: run, as: LightingAdvice.self
        )
    }
}

/// CLI 顧問呼叫的共同執行器：單發 → 解析 → decode 失敗重試一次 →
/// 型別化錯誤映射。光環境與音訊調音兩個顧問共用（機制只寫一份）；
/// 輸出型別由呼叫端指定（AdviceCodec 泛型 decode）。
enum CLIAdviceExecution {
    typealias Output = CLIProcessRunner.Output

    static func perform<T: Decodable>(
        engine: KnownCLIEngine,
        executable: URL,
        basePrompt: String,
        run: KnownCLIEngine.RunContext,
        as type: T.Type
    ) async throws -> T {
        do {
            return try await attempt(prompt: basePrompt, engine: engine, executable: executable, run: run, as: type)
        } catch let error as AdviceDecodeError {
            // CLI 自報的執行錯誤（如未認證）重試也不會好，直接映射
            if case let .cliReportedError(message) = error {
                throw mapReportedError(engineID: engine.id, message: message)
            }
            // 其餘 decode 失敗自動重試一次，prompt 附上修正指示
            do {
                return try await attempt(
                    prompt: basePrompt + "\n\n" + AdvicePrompt.retryInstruction,
                    engine: engine, executable: executable, run: run, as: type
                )
            } catch let retryError as AdviceDecodeError {
                throw AdviceError.decodeFailed(raw: rawText(from: retryError))
            }
        }
    }

    /// schema 檔一律寫進沙箱。寫不出來（沒有沙箱、磁碟問題）就回 nil——
    /// 少了 `--json-schema` 只是退回文字解析路徑，不該讓整次分析失敗。
    static func writeSchema(_ schemaJSON: String, into sandbox: URL?) -> URL? {
        guard let sandbox else { return nil }
        let url = sandbox.appendingPathComponent("advice-schema.json")
        do {
            try Data(schemaJSON.utf8).write(to: url, options: [.atomic])
            return url
        } catch {
            return nil
        }
    }

    private static func attempt<T: Decodable>(
        prompt: String,
        engine: KnownCLIEngine,
        executable: URL,
        run: KnownCLIEngine.RunContext,
        as type: T.Type
    ) async throws -> T {
        let invocation = engine.invocation(prompt: prompt, run: run)
        let output: CLIProcessRunner.Output
        // envelope 類的輸出解得開就代表答案完整，不必等行程自己結束
        let complete: @Sendable (String) -> Bool = { AdviceOutputCodec.looksLikeCompleteJSONObject($0) }
        let isComplete: (@Sendable (String) -> Bool)? = engine.codec.isSelfDelimitingJSON ? complete : nil
        do {
            output = try await CLIProcessRunner.run(
                executable: executable,
                arguments: invocation.arguments,
                stdin: invocation.stdin,
                timeout: run.timeout,
                isComplete: isComplete
            )
        } catch let error as AdviceError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AdviceError.engineNotFound(engineID: engine.id)
        }

        guard output.status == 0 else {
            throw mapNonZeroExit(engineID: engine.id, output: output)
        }
        do {
            return try AdviceCodec.decode(stdout: output.stdout, codec: engine.codec, as: type)
        } catch AdviceDecodeError.emptyOutput {
            // 退出碼 0 但沒有回應：agy headless 權限被拒就長這樣
            // （status 仍是 SUCCESS）。原因只在 stderr，接過來給使用者看，
            // 否則畫面上只會是一句無從下手的「沒有回應」。
            throw AdviceError.emptyResponse(
                engineID: engine.id,
                detail: sanitizedStderr(
                    output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
        }
    }

    private static func mapReportedError(engineID: String, message: String) -> AdviceError {
        if authMarkers.contains(where: message.lowercased().contains) {
            return .notLoggedIn(engineID: engineID)
        }
        return .processFailed(status: 0, stderr: sanitizedStderr(message))
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
}
