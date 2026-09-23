import Foundation

/// 乾淨結束哨兵：啟動時寫 `running`，走到 `applicationWillTerminate` 時改寫成 `clean`。
/// 下次啟動讀到 `running`，就是上次被 kill、crash 或斷電——MetricKit 的診斷要下次啟動
/// 才送達、有時還會漏，這條是最便宜的保底。
///
/// 一行：`running 116 2026-09-23T03:27:44Z`。不刪檔改寫成 `clean`，才分得出
/// 「第一次啟動」和「上次正常結束」。
final class ExitSentinel: Sendable {
    enum LastExit: String, Sendable {
        case firstLaunch, clean, crash
    }

    struct Outcome: Equatable, Sendable {
        let lastExit: LastExit
        let previousBuild: String?
        let previousLaunchedAt: Date?
    }

    let fileURL: URL

    init(directory: URL, instance: InstanceConfig = .current) {
        fileURL = directory.appendingPathComponent(Self.fileName(instance: instance))
    }

    /// 同機多實例（E2E）各寫各的，與 `DiagnosticLog.defaultFileName` 同一套命名。
    static func fileName(instance: InstanceConfig) -> String {
        guard let name = instance.name else { return "running.sentinel" }
        return "running-\(name).sentinel"
    }

    /// 回報上次結束的狀態，並寫下這次的 build 與啟動時間。
    func markRunning(build: String, now: Date = Date()) -> Outcome {
        let outcome: Outcome
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            outcome = Outcome(lastExit: .firstLaunch, previousBuild: nil, previousLaunchedAt: nil)
        } else if let previous = read() {
            outcome = Outcome(
                lastExit: previous.state == "clean" ? .clean : .crash,
                previousBuild: previous.build,
                previousLaunchedAt: previous.at
            )
        } else {
            // 有檔但讀不懂：寧可誤報一次「異常結束」，也不要漏掉
            outcome = Outcome(lastExit: .crash, previousBuild: nil, previousLaunchedAt: nil)
        }
        write(state: "running", build: build, at: now)
        return outcome
    }

    func markClean(build: String, now: Date = Date()) {
        write(state: "clean", build: build, at: now)
    }

    private func read() -> (state: String, build: String, at: Date)? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard parts.count == 3, let at = Self.iso.date(from: String(parts[2])) else { return nil }
        return (String(parts[0]), String(parts[1]), at)
    }

    /// 寫不進去就算了：哨兵不能反過來拖垮啟動。
    private func write(state: String, build: String, at: Date) {
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? "\(state) \(build) \(Self.iso.string(from: at))\n".write(to: fileURL, atomically: true, encoding: .utf8)
    }

    // DateFormatter / ISO8601DateFormatter 不是 Sendable；哨兵只在自己的檔路徑上讀寫，
    // 且字串格式固定，共用一個實例比每次分配划算。
    nonisolated(unsafe) private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
