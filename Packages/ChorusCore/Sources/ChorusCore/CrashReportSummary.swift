import Foundation

/// 一筆異常結束的摘要。來源有三：系統 `.ips`、MetricKit 診斷 JSON、只有哨兵知道的
/// 「上次沒走到 applicationWillTerminate」。純解析、不碰檔案系統。
///
/// 欄位缺了就給 nil、格式不對才回 nil——事後分析寧可少一欄，不能整筆不見。
/// `topFrames` 未符號化（Release 產物是 strip 過的），格式 `映像 + 位移`，
/// 事後用 `scripts/symbolicate-diagnostics.py` 配 dSYM 對回原始碼。
public struct CrashReportSummary: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// MetricKit 的 crash / hang / CPU 例外 / 磁碟寫入例外
        case crash, hang, cpuException, diskWrite
        /// 系統 `~/Library/Logs/DiagnosticReports/Chorus-*.ips`
        case ips
        /// 只有哨兵知道：上次沒正常結束，但沒找到對應的報告
        case uncleanExit
    }

    public let kind: Kind
    public let occurredAt: Date
    /// CFBundleVersion（build 號）；對 dSYM 用的就是它。
    public let appVersion: String?
    /// 例：`EXC_BAD_ACCESS (SIGSEGV)`；MetricKit 給的是 `exceptionType=1 signal=11`。
    public let exception: String?
    /// 最多 `maxFrames` 格，crash 點在前。
    public let topFrames: [String]
    /// diagnostics/ 裡的檔名，由收集器決定；解析出來時是空字串。
    public var fileName: String

    public static let maxFrames = 5

    public init(kind: Kind, occurredAt: Date, appVersion: String?, exception: String?, topFrames: [String], fileName: String) {
        self.kind = kind
        self.occurredAt = occurredAt
        self.appVersion = appVersion
        self.exception = exception
        self.topFrames = Array(topFrames.prefix(Self.maxFrames))
        self.fileName = fileName
    }
}

// MARK: - .ips

extension CrashReportSummary {
    /// `.ips`：第一行 JSON header（`timestamp`、`build_version`），第二行起 JSON body
    /// （`exception`、`faultingThread`、`threads`、`usedImages`）。
    public static func parseIPS(_ text: String) -> CrashReportSummary? {
        guard let newline = text.firstIndex(of: "\n") else { return nil }
        guard let header = jsonObject(String(text[..<newline])),
              let body = jsonObject(String(text[text.index(after: newline)...]))
        else { return nil }

        let occurredAt = (header["timestamp"] as? String).flatMap(ipsDate) ?? Date()
        let build = (header["build_version"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        var exception: String?
        if let info = body["exception"] as? [String: Any], let type = info["type"] as? String {
            exception = (info["signal"] as? String).map { "\(type) (\($0))" } ?? type
        }

        let images = body["usedImages"] as? [[String: Any]] ?? []
        let threads = body["threads"] as? [[String: Any]] ?? []
        let faulting = body["faultingThread"] as? Int ?? 0
        let frames = (threads.indices.contains(faulting) ? threads[faulting]["frames"] : nil) as? [[String: Any]] ?? []
        let topFrames = frames.prefix(maxFrames).map { frame -> String in
            let index = frame["imageIndex"] as? Int ?? -1
            let name = (images.indices.contains(index) ? images[index]["name"] as? String : nil) ?? "?"
            if let symbol = frame["symbol"] as? String {
                return "\(name) \(symbol) + \(frame["symbolLocation"] as? Int ?? 0)"
            }
            return "\(name) + \(frame["imageOffset"] as? Int ?? 0)"
        }

        return CrashReportSummary(
            kind: .ips, occurredAt: occurredAt, appVersion: build,
            exception: exception, topFrames: topFrames, fileName: ""
        )
    }

    /// `2026-09-23 11:27:44.00 +0800`
    static func ipsDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
        return formatter.date(from: text)
    }

    static func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
}

// MARK: - MetricKit

extension CrashReportSummary {
    /// `MXDiagnostic.jsonRepresentation()`。root frame 是最外層，crash 點在 `subFrames`
    /// 鏈的最深處——所以沿著每層第一個子節點走到底，取鏈尾反轉。
    public static func parseMetricKit(_ data: Data, kind: Kind, occurredAt: Date) -> CrashReportSummary? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let meta = root["diagnosticMetaData"] as? [String: Any]
        let build = meta?["appBuildVersion"] as? String

        var parts: [String] = []
        if let type = meta?["exceptionType"] { parts.append("exceptionType=\(type)") }
        if let signal = meta?["signal"] { parts.append("signal=\(signal)") }
        if let reason = meta?["terminationReason"] as? String, !reason.isEmpty { parts.append(reason) }
        let exception = parts.isEmpty ? nil : parts.joined(separator: " ")

        var chain: [String] = []
        if let tree = root["callStackTree"] as? [String: Any],
           let stacks = tree["callStacks"] as? [[String: Any]] {
            let stack = stacks.first { $0["threadAttributed"] as? Bool == true } ?? stacks.first
            var level = stack?["callStackRootFrames"] as? [[String: Any]]
            // 上限防呆：JSON 壞掉自我引用不會發生，但 512 格已遠超任何真實堆疊
            while let frame = level?.first, chain.count < 512 {
                let name = frame["binaryName"] as? String ?? "?"
                chain.append("\(name) + \(frame["offsetIntoBinaryTextSegment"] as? Int ?? 0)")
                level = frame["subFrames"] as? [[String: Any]]
            }
        }

        return CrashReportSummary(
            kind: kind, occurredAt: occurredAt, appVersion: build,
            exception: exception, topFrames: Array(chain.suffix(maxFrames).reversed()), fileName: ""
        )
    }
}
