/// (originID, seq) 去重快取（bounded LRU）。
/// 結構上收到者永不轉發，這層是重連重播等情況的保險絲。
public struct UpdateDeduplicator: Sendable {
    private struct Key: Hashable {
        let originID: String
        let seq: UInt64
    }

    private let capacity: Int
    private var seen: Set<Key> = []
    private var order: [Key] = []

    public init(capacity: Int = 512) {
        self.capacity = max(capacity, 1)
    }

    /// 回傳是否重複；新 key 會被記錄。
    public mutating func isDuplicate(originID: String, seq: UInt64) -> Bool {
        let key = Key(originID: originID, seq: seq)
        if seen.contains(key) { return true }
        seen.insert(key)
        order.append(key)
        if order.count > capacity {
            let evicted = order.removeFirst()
            seen.remove(evicted)
        }
        return false
    }
}
