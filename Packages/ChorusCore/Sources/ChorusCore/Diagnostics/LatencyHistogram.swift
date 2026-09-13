/// 固定桶的延遲直方圖：記憶體與樣本數無關，常駐量測幾天也不會長大。
///
/// 百分位回報的是**樣本所在桶的上界**（再以實際最大值封頂），精度取決於桶寬。
/// 基線與驗收比的是「有沒有越過 100 ms／500 ms／2 s 這幾條線」，桶界就放在那些線上。
public struct LatencyHistogram: Sendable, Equatable {
    public static let upperBoundsMillis: [Double] = [8, 16, 33, 50, 100, 250, 500, 1_000, 2_000, 5_000, 10_000]

    /// 最後一格是溢位桶（> 10 s）。
    public private(set) var bucketCounts: [Int]
    public private(set) var count = 0
    public private(set) var sumMillis: Double = 0
    public private(set) var maxMillis: Double = 0

    public init() {
        bucketCounts = Array(repeating: 0, count: Self.upperBoundsMillis.count + 1)
    }

    public mutating func record(millis: Double) {
        let value = max(0, millis)
        let index = Self.upperBoundsMillis.firstIndex { value <= $0 } ?? Self.upperBoundsMillis.count
        bucketCounts[index] += 1
        count += 1
        sumMillis += value
        maxMillis = max(maxMillis, value)
    }

    public mutating func record(_ duration: Duration) {
        record(millis: duration.millis)
    }

    public var meanMillis: Double? {
        count > 0 ? sumMillis / Double(count) : nil
    }

    /// `fraction` 取 0–1（0.95 ＝ P95）。沒有樣本回 nil。
    public func percentile(_ fraction: Double) -> Double? {
        guard count > 0 else { return nil }
        let clamped = min(max(fraction, 0), 1)
        let rank = max(1, Int((clamped * Double(count)).rounded(.up)))
        var cumulative = 0
        for (index, bucket) in bucketCounts.enumerated() {
            cumulative += bucket
            guard cumulative >= rank else { continue }
            guard index < Self.upperBoundsMillis.count else { return maxMillis }
            return min(Self.upperBoundsMillis[index], maxMillis)
        }
        return maxMillis
    }
}

extension Duration {
    /// 毫秒（含小數）。診斷輸出與直方圖用。
    public var millis: Double {
        let parts = components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15
    }
}
