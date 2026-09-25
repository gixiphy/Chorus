import ChorusCore
import Foundation
import MetricKit
import Synchronization

/// 異常結束的收集器。三個來源都進同一個 `~/Library/Logs/Chorus/diagnostics/`：
/// 1. 乾淨結束哨兵（`ExitSentinel`）——上次沒走到 `applicationWillTerminate`
/// 2. 系統 `~/Library/Logs/DiagnosticReports/Chorus-*.ips`——非沙盒才讀得到；
///    只存摘要與原檔路徑，不複製整份（系統自己會留 30 天）
/// 3. MetricKit——下次啟動才送達的 crash / hang / CPU / 磁碟寫入診斷，整份 JSON 落地，
///    事後配 dSYM 符號化（`scripts/symbolicate-diagnostics.py`）
///
/// 每份是一個 envelope：`{"summary": …, "sourcePath"?: …, "diagnostic"?: …}`，檔名以時間開頭，
/// 超過 `keep` 份刪最舊。寫檔都在背景 queue；失敗只寫一行 log，**不能反過來拖垮 App**。
final class CrashReportCollector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    struct Snapshot: Sendable {
        let lastExit: ExitSentinel.LastExit?
        /// 新的在前，最多 5 筆。
        let recent: [CrashReportSummary]
        let unacknowledged: CrashReportSummary?
        let count: Int
    }

    static let shared = CrashReportCollector(
        directory: DiagnosticLog.shared.directory.appendingPathComponent("diagnostics", isDirectory: true),
        reportsDirectory: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true),
        defaults: InstanceConfig.current.defaults,
        instance: .current
    )

    let directory: URL
    let sentinel: ExitSentinel

    private let reportsDirectory: URL
    private let defaults: UserDefaults
    private let keep: Int
    private let processName: String
    private let log: ChorusLog
    private let queue = DispatchQueue(label: "com.hermes.Chorus.crash-reports", qos: .utility)

    private struct State {
        var lastExit: ExitSentinel.LastExit?
        var unacknowledged: CrashReportSummary?
    }
    private let state = Mutex(State())

    private static let lastScanKey = "crashReports.lastIPSScan"
    private static let acknowledgedKey = "crashReports.acknowledgedFile"

    init(
        directory: URL,
        reportsDirectory: URL,
        defaults: UserDefaults,
        instance: InstanceConfig,
        keep: Int = 20,
        processName: String = "Chorus",
        log: ChorusLog = .app
    ) {
        self.directory = directory
        self.reportsDirectory = reportsDirectory
        self.defaults = defaults
        self.keep = max(1, keep)
        self.processName = processName
        self.log = log
        self.sentinel = ExitSentinel(directory: directory, instance: instance)
        super.init()
    }

    /// 預設引數會用到，所以不能是 private（預設引數不能引用比函式本身更窄的宣告）。
    static var bundleBuild: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
    }

    // MARK: - 生命週期

    /// 啟動時呼叫一次：哨兵、MetricKit 訂閱、掃 `.ips`。掃描在背景，啟動不等它。
    func start(build: String = CrashReportCollector.bundleBuild) {
        let outcome = sentinel.markRunning(build: build)
        state.withLock { $0.lastExit = outcome.lastExit }
        switch outcome.lastExit {
        case .crash:
            let launched = outcome.previousLaunchedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "?"
            log.error("上次異常結束（build \(outcome.previousBuild ?? "?")，啟動於 \(launched)）")
        case .clean:
            log.info("上次正常結束")
        case .firstLaunch:
            log.info("第一次啟動（沒有哨兵）")
        }
        MXMetricManager.shared.add(self)
        queue.async { [self] in
            let found = scanSystemReports()
            // 哨兵說 crash、系統卻沒留報告（例如被 kill -9、斷電）：補一筆，UI 才提示得出來
            if outcome.lastExit == .crash, found == 0 {
                let summary = CrashReportSummary(
                    kind: .uncleanExit,
                    occurredAt: outcome.previousLaunchedAt ?? Date(),
                    appVersion: outcome.previousBuild,
                    exception: nil,
                    topFrames: [],
                    fileName: ""
                )
                store(summary: summary)
            }
        }
    }

    func markCleanExit(build: String = CrashReportCollector.bundleBuild) {
        sentinel.markClean(build: build)
    }

    /// 測試用：等背景工作做完。
    func waitForPendingWork() {
        queue.sync {}
    }

    // MARK: - 查詢

    var unacknowledged: CrashReportSummary? {
        state.withLock { $0.unacknowledged }
    }

    func acknowledge() {
        let fileName = state.withLock { state -> String? in
            defer { state.unacknowledged = nil }
            return state.unacknowledged?.fileName
        }
        if let fileName { defaults.set(fileName, forKey: Self.acknowledgedKey) }
    }

    /// 讀磁碟（最多 keep 個小檔）；背景 queue 或 health 呼叫都可以，不經主執行緒。
    func snapshot() -> Snapshot {
        let names = storedFileNames()
        let recent = names.reversed().prefix(5).compactMap { loadSummary(fileName: $0) }
        let (lastExit, unacknowledged) = state.withLock { ($0.lastExit, $0.unacknowledged) }
        return Snapshot(lastExit: lastExit, recent: Array(recent), unacknowledged: unacknowledged, count: names.count)
    }

    // MARK: - 來源：系統 .ips

    /// 收 `Chorus-*.ips` 裡修改時間晚於上次掃描的。讀不到（沙盒、TCC、目錄不存在）就當沒有。
    @discardableResult
    func scanSystemReports() -> Int {
        let since = defaults.object(forKey: Self.lastScanKey) as? Date ?? .distantPast
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: reportsDirectory.path) else { return 0 }
        var newest = since
        var found = 0
        for name in names where name.hasPrefix("\(processName)-") && name.hasSuffix(".ips") {
            let url = reportsDirectory.appendingPathComponent(name)
            guard let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
                  modified > since,
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  let summary = CrashReportSummary.parseIPS(text)
            else { continue }
            store(summary: summary, sourcePath: url.path)
            log.error("系統 crash 報告：\(name) \(summary.exception ?? "?") build \(summary.appVersion ?? "?")")
            found += 1
            newest = max(newest, modified)
        }
        defaults.set(newest, forKey: Self.lastScanKey)
        return found
    }

    // MARK: - 來源：MetricKit

    /// `MXDiagnostic.jsonRepresentation()` 整份落地，摘要進 envelope。
    func storeDiagnostic(_ data: Data, kind: CrashReportSummary.Kind, at: Date) {
        guard let summary = CrashReportSummary.parseMetricKit(data, kind: kind, occurredAt: at) else {
            log.error("MetricKit \(kind.rawValue) 診斷解析失敗（\(data.count) bytes）")
            return
        }
        // **原始 bytes 直接往下傳，不 parse 再 re-serialize**：見 `store` 的註解。
        store(summary: summary, diagnosticJSON: data)
        let text = "MetricKit \(kind.rawValue) 診斷：\(summary.exception ?? "?") build \(summary.appVersion ?? "?")"
        if kind == .crash { log.error(text) } else { log.notice(text) }
    }

    /// MetricKit 在自己的 queue 上呼叫。`MXDiagnosticPayload` 不是 Sendable，
    /// 所以在這條執行緒先轉成 Data，再丟背景 queue 寫檔。
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        var items: [(Data, CrashReportSummary.Kind, Date)] = []
        for payload in payloads {
            let at = payload.timeStampEnd
            for diagnostic in payload.crashDiagnostics ?? [] { items.append((diagnostic.jsonRepresentation(), .crash, at)) }
            for diagnostic in payload.hangDiagnostics ?? [] { items.append((diagnostic.jsonRepresentation(), .hang, at)) }
            for diagnostic in payload.cpuExceptionDiagnostics ?? [] { items.append((diagnostic.jsonRepresentation(), .cpuException, at)) }
            for diagnostic in payload.diskWriteExceptionDiagnostics ?? [] { items.append((diagnostic.jsonRepresentation(), .diskWrite, at)) }
        }
        guard !items.isEmpty else { return }
        queue.async { [self] in
            for (data, kind, at) in items { storeDiagnostic(data, kind: kind, at: at) }
        }
    }

    // MARK: - 存檔

    static func fileName(kind: CrashReportSummary.Kind, at: Date) -> String {
        "\(stampFormatter.string(from: at))-\(kind.rawValue).json"
    }

    // DateFormatter 不是 Sendable；檔名格式固定，共用一個 UTC 實例即可。
    nonisolated(unsafe) private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }()

    /// 把一筆診斷寫成 envelope 檔。
    ///
    /// `diagnosticJSON` 是 MetricKit 給的**原始 JSON bytes**，刻意不 parse 成
    /// Foundation 物件再重新序列化——那條路會在真的出事時再炸一次。
    ///
    /// 實際發生過（2026-09-26，build 121）：`_NSJSONWriter dataWithRootObject:`
    /// 在 `com.hermes.Chorus.crash-reports` 這條 queue 上撞到堆疊保護頁
    /// （SIGBUS／KERN_PROTECTION_FAILURE）。堆疊只有 47 格、不是遞迴太深；
    /// 爆掉的是 `.sortedKeys` 走的 `CFSortIndexes` → `__CFSimpleMergeSort`
    /// 在單一格裡要的暫存空間。背景 DispatchQueue 的執行緒堆疊是 512 KB，
    /// 不是主執行緒的 8 MB，所以這裡撐不住而主執行緒上看不出問題。
    /// 後果是「處理 crash 的過程中自己 crash」，形成迴圈：
    /// crash → MetricKit 回報 → 寫檔時 crash → 再回報。
    ///
    /// 改成把 summary 正常序列化（鍵少又固定），再以位元組接上原始的
    /// diagnostic——那一大包完全不進 Foundation 的寫入器。輸出仍是合法 JSON、
    /// 鍵名不變，讀取端（`summaryObject` 那條）照舊。
    private func store(summary: CrashReportSummary, sourcePath: String? = nil, diagnosticJSON: Data? = nil) {
        var summary = summary
        summary.fileName = Self.fileName(kind: summary.kind, at: summary.occurredAt)
        guard let summaryData = try? JSONEncoder.diagnostics.encode(summary),
              let summaryObject = try? JSONSerialization.jsonObject(with: summaryData)
        else { return }
        var envelope: [String: Any] = ["summary": summaryObject]
        if let sourcePath { envelope["sourcePath"] = sourcePath }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
            if let diagnosticJSON, let close = data.lastIndex(of: UInt8(ascii: "}")) {
                // {...\n} → {...,\n  "diagnostic": <原始 bytes>\n}
                var spliced = data[..<close]
                spliced.append(contentsOf: ",\n  \"diagnostic\" : ".utf8)
                spliced.append(diagnosticJSON)
                spliced.append(contentsOf: "\n}".utf8)
                data = Data(spliced)
            }
            try data.write(to: directory.appendingPathComponent(summary.fileName), options: .atomic)
        } catch {
            log.error("診斷寫檔失敗：\(error.localizedDescription)")
            return
        }
        prune()
        // hang / CPU / 磁碟寫入只是紀錄，不打擾使用者；crash 類才算「未確認」
        let isCrash = [.crash, .ips, .uncleanExit].contains(summary.kind)
        let acknowledged = defaults.string(forKey: Self.acknowledgedKey)
        if isCrash, summary.fileName != acknowledged {
            state.withLock { state in
                if state.unacknowledged.map({ $0.occurredAt <= summary.occurredAt }) ?? true {
                    state.unacknowledged = summary
                }
            }
        }
    }

    /// 檔名以 UTC 時間開頭，字典序即時間序。
    private func storedFileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }
            .sorted()
    }

    private func prune() {
        let names = storedFileNames()
        guard names.count > keep else { return }
        for name in names.prefix(names.count - keep) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    private func loadSummary(fileName: String) -> CrashReportSummary? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)),
              let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let summaryObject = envelope["summary"],
              let summaryData = try? JSONSerialization.data(withJSONObject: summaryObject)
        else { return nil }
        return try? JSONDecoder.diagnostics.decode(CrashReportSummary.self, from: summaryData)
    }
}

extension JSONEncoder {
    /// 日期用 ISO 8601，事後用眼睛看得懂、腳本也好解析。
    nonisolated(unsafe) static let diagnostics: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

extension JSONDecoder {
    nonisolated(unsafe) static let diagnostics: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
