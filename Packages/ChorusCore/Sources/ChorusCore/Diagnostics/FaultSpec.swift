import Foundation

/// 可注入故障的位置。只有 DEBUG build 會真的去讀它（見 App 端 `FaultRegistry`）。
public enum FaultPoint: String, Sendable, CaseIterable {
    case cloudWrite = "cloud.write"
    case cloudRead = "cloud.read"
    case cloudScan = "cloud.scan"
    /// iCloud Drive 根目錄存在檢查與修改時間這類 metadata 查詢。
    case cloudMetadata = "cloud.metadata"
    /// 同步 session 的 hello：`withhold` ＝ 連線 ready 後不送 hello。
    case syncHello = "sync.hello"
    case syncSend = "sync.send"
    /// 診斷紀錄寫檔（背景 worker 上）。
    case logWrite = "log.write"

    public func supports(_ behavior: FaultBehavior) -> Bool {
        switch (self, behavior) {
        case (.syncHello, .withhold), (.syncHello, .delay):
            true
        case (.syncHello, _), (_, .withhold):
            false
        default:
            true
        }
    }
}

public enum FaultBehavior: Sendable, Equatable {
    /// 延遲這麼久再繼續。
    case delay(Duration)
    /// 卡住，直到故障被解除（App 端另有安全上限）。
    case hang
    /// 立刻失敗。
    case fail
    /// 不送出（只用於協定訊息）。
    case withhold
}

/// 故障規格的文字格式：`cloud.write=delay:3.5`、`sync.hello=withhold`、
/// `cloud.write=off`（解除）。啟動參數 `--fault` 與測試掛鉤共用。
public enum FaultSpec {
    public enum ParseError: Error, Equatable {
        case malformed(String)
        case unknownPoint(String)
        case unknownBehavior(String)
        case unsupported(point: FaultPoint, behavior: String)
        case delayOutOfRange(String)
    }

    public static let maxDelay: Duration = .seconds(600)

    /// behavior 為 nil 表示解除該位置的故障。
    public static func parse(_ text: String) throws(ParseError) -> (point: FaultPoint, behavior: FaultBehavior?) {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
        guard parts.count == 2 else { throw .malformed(text) }
        let pointName = String(parts[0])
        guard let point = FaultPoint(rawValue: pointName) else { throw .unknownPoint(pointName) }

        let raw = String(parts[1])
        let behavior: FaultBehavior?
        switch raw {
        case "off":
            behavior = nil
        case "hang":
            behavior = .hang
        case "fail":
            behavior = .fail
        case "withhold":
            behavior = .withhold
        case _ where raw.hasPrefix("delay:"):
            guard let seconds = Double(raw.dropFirst("delay:".count)),
                  seconds.isFinite, seconds > 0
            else { throw .delayOutOfRange(raw) }
            let duration = Duration.milliseconds(max(1, Int64((seconds * 1_000).rounded())))
            guard duration <= maxDelay else { throw .delayOutOfRange(raw) }
            behavior = .delay(duration)
        default:
            throw .unknownBehavior(raw)
        }
        if let behavior, !point.supports(behavior) {
            throw .unsupported(point: point, behavior: raw)
        }
        return (point, behavior)
    }
}
