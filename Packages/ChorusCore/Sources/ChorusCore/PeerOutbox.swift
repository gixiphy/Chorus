/// 送往單一 peer 的有界佇列（每個 peer 一份，同時只有一件在送）。
///
/// **可取代的狀態在排隊時就合併**：同一個 key 的 stateUpdate、同一個來源的環境光回報、
/// 心跳只留最新一份；stateReport 逐 key 合併。慢連線上不會追播幾分鐘前的滑桿中間值
/// （接收端以 (originID, seq) 去重、以 HLC 裁決，不需要連續的 seq）。
///
/// **合併只往回看到上一則不可取代的訊息為止**（順序屏障）：指令、fullState、
/// 場景相關的先後不會被打亂。放不下時回 `.overflow`——呼叫端應斷線，讓重連時互換的
/// fullState 補回狀態，而不是默默丟掉一則指令。
public struct PeerOutbox: Sendable {
    public struct Limits: Sendable, Equatable {
        public var maxItems: Int
        public var maxBytes: Int

        public init(maxItems: Int = 64, maxBytes: Int = 2 << 20) {
            self.maxItems = max(1, maxItems)
            self.maxBytes = max(1, maxBytes)
        }
    }

    public enum EnqueueResult: Sendable, Equatable {
        case queued
        /// 併進了佇列裡同一個 slot 的那一則。
        case merged
        case overflow
    }

    private enum Slot: Hashable {
        case ping
        case pong
        case ambient(originID: String)
        case update(originID: String, key: ControlKey)
        case report
    }

    private struct Item {
        var envelope: Envelope
        var bytes: Int
        let slot: Slot?
    }

    public let limits: Limits
    private var items: [Item] = []
    public private(set) var byteCount = 0

    public init(limits: Limits = Limits()) {
        self.limits = limits
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    /// `size` 是這則編碼後的大小。
    public mutating func enqueue(_ envelope: Envelope, size: Int) -> EnqueueResult {
        if let slot = Self.slot(for: envelope.msg), let index = coalescibleIndex(for: slot) {
            let existing = items[index]
            let merged = Self.merge(existing.envelope, with: envelope)
            // 報告合併後的實際大小要重新編碼才知道；用兩者相加當上界
            let mergedBytes = merged.isReportMerge ? existing.bytes + size : size
            guard byteCount - existing.bytes + mergedBytes <= limits.maxBytes else { return .overflow }
            byteCount += mergedBytes - existing.bytes
            items[index] = Item(envelope: merged.envelope, bytes: mergedBytes, slot: slot)
            return .merged
        }
        guard items.count < limits.maxItems, byteCount + size <= limits.maxBytes else { return .overflow }
        items.append(Item(envelope: envelope, bytes: size, slot: Self.slot(for: envelope.msg)))
        byteCount += size
        return .queued
    }

    public mutating func dequeue() -> Envelope? {
        guard !items.isEmpty else { return nil }
        let item = items.removeFirst()
        byteCount -= item.bytes
        return item.envelope
    }

    // MARK: - 合併規則

    private static func slot(for message: SyncMessage) -> Slot? {
        switch message {
        case .ping: .ping
        case .pong: .pong
        case let .ambientReport(report): .ambient(originID: report.originID)
        case let .stateUpdate(update): .update(originID: update.originID, key: update.key)
        case .stateReport: .report
        case .hello, .command, .fullState, .setDeviceOffset, .stateQuery: nil
        }
    }

    /// 從尾端往回找同一個 slot；碰到不可取代的訊息就停。
    private func coalescibleIndex(for slot: Slot) -> Int? {
        for index in items.indices.reversed() {
            guard let existing = items[index].slot else { return nil }
            if existing == slot { return index }
        }
        return nil
    }

    private static func merge(_ old: Envelope, with new: Envelope) -> (envelope: Envelope, isReportMerge: Bool) {
        guard case let .stateReport(earlier) = old.msg, case let .stateReport(later) = new.msg else {
            return (new, false)
        }
        var entries = earlier.entries
        for entry in later.entries {
            if let index = entries.firstIndex(where: { $0.key == entry.key }) {
                entries[index] = entry
            } else {
                entries.append(entry)
            }
        }
        return (Envelope(msg: .stateReport(StateReport(entries: entries))), true)
    }
}
