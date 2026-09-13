/// 診斷紀錄的有界緩衝：呼叫端只做這一步，寫檔交給背景 worker。
///
/// 磁碟卡住或短時間大量出錯時，緩衝會滿——這時**丟新的一般訊息、保留 error**
/// （預留一段額度），並累計丟了幾行，由 worker 寫一行說明。診斷紀錄不能反過來
/// 拖住呼叫端，也不能無界吃記憶體。
public struct BoundedLogBuffer: Sendable {
    public struct Limits: Sendable, Equatable {
        public var maxLines: Int
        public var maxBytes: Int
        /// 保留給 error 的行數：一般訊息把緩衝灌滿時，錯誤仍寫得進來。
        public var reservedErrorLines: Int
        public var maxLineBytes: Int

        public init(
            maxLines: Int = 2_000,
            maxBytes: Int = 1 << 20,
            reservedErrorLines: Int = 200,
            maxLineBytes: Int = 8 << 10
        ) {
            self.maxLines = max(1, maxLines)
            self.maxBytes = max(1, maxBytes)
            self.reservedErrorLines = min(max(0, reservedErrorLines), self.maxLines - 1)
            self.maxLineBytes = max(32, maxLineBytes)
        }
    }

    public enum Priority: Sendable {
        case normal
        case error
    }

    public static let truncationMarker = "…（截斷）\n"

    public let limits: Limits
    public private(set) var lines: [String] = []
    public private(set) var byteCount = 0
    public private(set) var droppedCount = 0

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    /// 回傳這一行有沒有收進來。
    @discardableResult
    public mutating func append(_ line: String, priority: Priority = .normal) -> Bool {
        let bounded = Self.truncate(line, toBytes: limits.maxLineBytes)
        let size = bounded.utf8.count
        let reservedLines = priority == .error ? 0 : limits.reservedErrorLines
        let reservedBytes = priority == .error ? 0 : limits.maxBytes * limits.reservedErrorLines / limits.maxLines
        guard lines.count < limits.maxLines - reservedLines,
              byteCount + size <= limits.maxBytes - reservedBytes
        else {
            droppedCount += 1
            return false
        }
        lines.append(bounded)
        byteCount += size
        return true
    }

    /// 取出全部待寫的行與丟棄數，緩衝歸零。
    public mutating func drain() -> (lines: [String], dropped: Int) {
        let taken = (lines, droppedCount)
        lines = []
        byteCount = 0
        droppedCount = 0
        return taken
    }

    /// 截到 `maxBytes` 以內並加上標記；不切斷多位元組字元。
    public static func truncate(_ line: String, toBytes maxBytes: Int) -> String {
        guard line.utf8.count > maxBytes else { return line }
        var prefix = Array(line.utf8.prefix(max(0, maxBytes - truncationMarker.utf8.count)))
        // 退回合法的 UTF-8 邊界：去掉尾端的延續位元組與不完整字元的起始位元組
        while let last = prefix.last, last & 0xC0 == 0x80 {
            prefix.removeLast()
        }
        if let last = prefix.last, last >= 0xC0 {
            prefix.removeLast()
        }
        return String(decoding: prefix, as: UTF8.self) + truncationMarker
    }
}
