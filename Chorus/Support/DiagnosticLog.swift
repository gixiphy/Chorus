import ChorusCore
import Foundation
import OSLog
import Synchronization

/// 落地的診斷紀錄：`~/Library/Logs/Chorus/chorus.log`，2 MB 一輪、留三輪。
///
/// 為什麼 unified log 不夠：這台機器的 log store 只留得住約兩天、`.debug`
/// 根本不落地，而「聲音突然變怪、狀態列圖示跑掉、重開才好」這種事是
/// 事後才被講出來的——到時候 `log show` 要嘛撈不到，要嘛只剩 AppKit 的
/// 錯誤而沒有我們自己當時在做什麼。檔案是給**事後**分析用的，所以
/// 只收 `.info` 以上；`.debug` 仍走 os_log（`log stream` 側錄用）。
///
/// **呼叫端只排進有界緩衝**，開檔、寫入、輪替都在背景 worker 上做：磁碟忙或
/// 卡住時不拖住主執行緒，緩衝滿了丟一般訊息、保留 error，並寫一行丟棄數
/// （`BoundedLogBuffer`）。**不在 realtime 執行緒呼叫**——IOProc 裡本來就沒有
/// 任何 log 呼叫，這條規矩不變。
final class DiagnosticLog: @unchecked Sendable {
    enum Level: String, Sendable {
        case debug = "D"
        case info = "I"
        case notice = "N"
        case error = "E"
    }

    static let shared = DiagnosticLog(
        directory: defaultDirectory(environment: ProcessInfo.processInfo.environment),
        fileName: defaultFileName(instance: InstanceConfig.current)
    )

    /// `~/Library/Logs/Chorus`（未沙盒化；沙盒化時會落在容器內的同一相對路徑）。
    ///
    /// **測試行程改寫暫存目錄**：test host 就是 Chorus.app 本尊，單元測試
    /// 一跑就把假裝置（fake-headphones）的幾百行灌進使用者真正的紀錄，
    /// 事後分析時會被那些假事件帶著走。
    static func defaultDirectory(environment: [String: String]) -> URL {
        if environment["XCTestConfigurationFilePath"] != nil || environment["XCTestBundlePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("chorus-tests/Logs", isDirectory: true)
        }
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return library.appendingPathComponent("Logs/Chorus", isDirectory: true)
    }

    /// 同機多實例（E2E）各寫各的檔，別把兩個行程的時間軸攪在一起。
    static func defaultFileName(instance: InstanceConfig) -> String {
        guard let name = instance.name else { return "chorus.log" }
        return "chorus-\(name).log"
    }

    let directory: URL
    let fileName: String
    /// 超過就輪替。預設 2 MB：一行約 100 bytes，夠裝好幾天的正常使用。
    let maxBytes: Int
    /// 連現用檔一共留幾份。
    let keep: Int

    var fileURL: URL { directory.appendingPathComponent(fileName) }

    private struct Pending {
        var buffer: BoundedLogBuffer
        var drainScheduled = false
        let formatter: DateFormatter
    }

    private let pending: Mutex<Pending>
    private let queue = DispatchQueue(label: "com.hermes.Chorus.diagnostic-log", qos: .utility)
    /// nil ＝ 用 `FaultRegistry.shared`（到寫檔時才取，避免與 shared 互相初始化）。
    private let faults: FaultRegistry?

    // 以下只在 queue 上讀寫
    private var descriptor: Int32 = -1
    private var bytesWritten = 0
    private let workerFormatter = DiagnosticLog.makeFormatter()

    init(
        directory: URL,
        fileName: String = "chorus.log",
        maxBytes: Int = 2_000_000,
        keep: Int = 3,
        limits: BoundedLogBuffer.Limits = .init(),
        faults: FaultRegistry? = nil
    ) {
        self.directory = directory
        self.fileName = fileName
        self.maxBytes = maxBytes
        self.keep = max(1, keep)
        self.faults = faults
        pending = Mutex(Pending(buffer: BoundedLogBuffer(limits: limits), formatter: Self.makeFormatter()))
    }

    deinit {
        if descriptor >= 0 { close(descriptor) }
    }

    private static func makeFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }

    /// 一行：`2026-09-02 12:49:30.276 N [focus] 訊息`。訊息裡的換行改成
    /// `⏎`，讓每一行永遠是一筆——事後用 grep 與 sort 才不會被多行拆散。
    /// 時間戳在呼叫當下取，寫檔晚一點也不會亂序。
    func write(level: Level, category: String, message: String) {
        let now = Date()
        let flattened = message.replacingOccurrences(of: "\n", with: "⏎")
        let scheduleDrain = pending.withLock { pending -> Bool in
            let line = "\(pending.formatter.string(from: now)) \(level.rawValue) [\(category)] \(flattened)\n"
            pending.buffer.append(line, priority: level == .error ? .error : .normal)
            guard !pending.drainScheduled else { return false }
            pending.drainScheduled = true
            return true
        }
        if scheduleDrain {
            queue.async { self.drain() }
        }
    }

    /// 等緩衝寫完，最多 `timeout`。回傳是否在期限內寫完——磁碟卡住時不陪著等
    /// （結束 App 用 100 ms；測試用它確定檔案已經寫進去）。
    @discardableResult
    func flush(timeout: Duration = .seconds(2)) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async {
            self.drain()
            done.signal()
        }
        return done.wait(timeout: .now() + timeout.millis / 1_000) == .success
    }

    /// 現有的輪替檔（含現用檔），新的在前。給「在 Finder 顯示」與測試用。
    func existingFiles() -> [URL] {
        var files = [fileURL]
        for index in 1..<keep {
            files.append(rotatedURL(index))
        }
        return files.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - 背景寫檔（queue 上）

    private func drain() {
        while true {
            let batch = pending.withLock { pending -> (lines: [String], dropped: Int)? in
                let batch = pending.buffer.drain()
                guard !batch.lines.isEmpty || batch.dropped > 0 else {
                    pending.drainScheduled = false
                    return nil
                }
                return batch
            }
            guard let batch else { return }
            for line in batch.lines {
                append(line)
            }
            if batch.dropped > 0 {
                append("\(workerFormatter.string(from: Date())) N [log] 紀錄緩衝已滿，丟棄 \(batch.dropped) 行\n")
            }
        }
    }

    private func append(_ line: String) {
        guard (try? (faults ?? FaultRegistry.shared).injectBlocking(.logWrite)) != nil,
              let data = line.data(using: .utf8)
        else { return }
        if descriptor < 0 { open() }
        if descriptor >= 0, bytesWritten + data.count > maxBytes { rotate() }
        guard descriptor >= 0 else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
        bytesWritten += data.count
    }

    private func rotatedURL(_ index: Int) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        return directory.appendingPathComponent("\(base).\(index).\(ext)")
    }

    /// queue 上呼叫。開不了就靜靜放棄——診斷紀錄不能反過來拖垮 App。
    private func open() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = Darwin.open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        descriptor = fd
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        bytesWritten = (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// queue 上呼叫。`chorus.log → chorus.1.log → chorus.2.log`，最舊的丟掉。
    private func rotate() {
        close(descriptor)
        descriptor = -1
        let manager = FileManager.default
        try? manager.removeItem(at: rotatedURL(keep - 1))
        if keep > 1 {
            for index in stride(from: keep - 2, through: 1, by: -1) {
                let from = rotatedURL(index)
                if manager.fileExists(atPath: from.path) {
                    try? manager.moveItem(at: from, to: rotatedURL(index + 1))
                }
            }
            try? manager.moveItem(at: fileURL, to: rotatedURL(1))
        } else {
            try? manager.removeItem(at: fileURL)
        }
        open()
    }
}

/// 各模組的 logger：同一句話同時進 os_log（`log stream` 即時看）與
/// `DiagnosticLog`（事後翻）。取代直接拿 `Logger`——兩條路只寫一次。
///
/// 訊息一律 `.public`：本來 24 個呼叫點就全部標 public，這裡沒有隱私
/// 語意上的損失；裝置 UID 與 bundle ID 正是事後分析要的東西。
struct ChorusLog: Sendable {
    static let subsystem = "com.hermes.Chorus"

    let category: String
    private let logger: Logger
    private let sink: DiagnosticLog

    init(category: String, sink: DiagnosticLog = .shared) {
        self.category = category
        self.logger = Logger(subsystem: Self.subsystem, category: category)
        self.sink = sink
    }

    func debug(_ message: @autoclosure () -> String) { emit(.debug, message()) }
    func info(_ message: @autoclosure () -> String) { emit(.info, message()) }
    func notice(_ message: @autoclosure () -> String) { emit(.notice, message()) }
    func error(_ message: @autoclosure () -> String) { emit(.error, message()) }

    private func emit(_ level: DiagnosticLog.Level, _ text: String) {
        switch level {
        case .debug: logger.debug("\(text, privacy: .public)")
        case .info: logger.info("\(text, privacy: .public)")
        case .notice: logger.notice("\(text, privacy: .public)")
        case .error: logger.error("\(text, privacy: .public)")
        }
        // .debug 不落地：每個 AudioWorker snapshot 都會走到的那幾條會把
        // 檔案灌滿，而它們本來就是給 `log stream` 側錄看的
        guard level != .debug else { return }
        sink.write(level: level, category: category, message: text)
    }
}

// MARK: - 各模組共用的 logger

extension ChorusLog {
    /// App 生命週期（啟動、結束）。
    static let app = ChorusLog(category: "app")
    /// 顯示器：列舉變動、亮度、電源。
    static let display = ChorusLog(category: "display")
    /// 限時場景（B7）。
    static let focus = ChorusLog(category: "focus")
    /// 場景套用與還原逐條的結果。
    static let automation = ChorusLog(category: "automation")
}

extension Double {
    /// 診斷紀錄用的兩位小數——音量、亮度、平衡都是 0–1 的量，
    /// 印 17 位只是在製造噪音。
    var diag2: String { String(format: "%.2f", self) }
}

extension Float {
    var diag2: String { String(format: "%.2f", self) }
}

extension ControlRequest {
    /// 一條請求的人話：`set display:ASUS brightness 0.30`、跨機的前面帶 `@peer`。
    /// 與設定頁「場景」列的寫法對齊，使用者對得上。
    var diagnosticDescription: String {
        let property = property?.rawValue ?? action?.rawValue ?? "?"
        let value = value.map { " \($0)" } ?? ""
        let peer = peer.map { "@\($0) " } ?? ""
        return "\(peer)\(verb.rawValue) \(target.stringValue) \(property)\(value)"
    }
}
