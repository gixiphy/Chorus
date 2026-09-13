/// 生產端的「只留最新值」信箱：在排進硬體 worker 之前就合併。
///
/// 拖曳滑桿一秒產生幾十個值；以前每個值都排一個 closure 進序列 queue，硬體呼叫
/// 慢下來時 queue 裡堆的是一整串馬上就過時的中間值。現在同一個 key 只留最後一個，
/// worker 醒來一次拿走全部。`put` 回 true 時呼叫端要排一次 worker（每輪只排一次）。
///
/// key 依第一次出現的順序取出（不同屬性之間的先後維持呼叫順序）。
public struct LatestValueMailbox<Key: Hashable & Sendable, Value: Sendable>: Sendable {
    private var values: [Key: Value] = [:]
    private var order: [Key] = []
    private var drainScheduled = false

    public init() {}

    public var isEmpty: Bool { order.isEmpty }
    public var count: Int { order.count }

    /// 放入最新值；`combine` 決定和還沒取走的舊值怎麼合（預設直接取代）。
    /// 回傳 true ＝ 這一輪還沒排 worker，呼叫端要排一次。
    public mutating func put(
        _ value: Value,
        for key: Key,
        combine: (_ pending: Value, _ new: Value) -> Value = { _, new in new }
    ) -> Bool {
        if let pending = values[key] {
            values[key] = combine(pending, value)
        } else {
            values[key] = value
            order.append(key)
        }
        guard !drainScheduled else { return false }
        drainScheduled = true
        return true
    }

    /// worker 端取走全部。之後再 `put` 會重新要求排程。
    public mutating func take() -> [(key: Key, value: Value)] {
        let taken = order.compactMap { key in values[key].map { (key: key, value: $0) } }
        values = [:]
        order = []
        drainScheduled = false
        return taken
    }
}
