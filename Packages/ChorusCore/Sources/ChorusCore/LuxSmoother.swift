import Foundation

/// 光感器讀值的遲滯平滑：只有變化夠大（log 空間相對變化超過門檻）
/// 且距上次 commit 夠久，才產出新的 committed lux —— 避免亮度隨感器雜訊抖動。
/// 純邏輯：時間由呼叫端注入。
public struct LuxSmoother: Sendable {
    /// 相對變化門檻（0.10 = (1+lux) 比值超過 ±10% 才算變化）。
    public let relativeThreshold: Double
    /// 兩次 commit 的最小間隔（毫秒）。
    public let minIntervalMillis: Int64

    private var committedValue: Double?
    private var lastCommitMillis: Int64 = 0

    public init(relativeThreshold: Double = 0.10, minIntervalMillis: Int64 = 2000) {
        self.relativeThreshold = relativeThreshold
        self.minIntervalMillis = minIntervalMillis
    }

    /// 目前已 commit 的 lux（尚無樣本時為 nil）。
    public var committed: Double? { committedValue }

    /// 餵入一筆原始讀值。回傳非 nil 表示新的 committed lux，呼叫端應據此調整亮度。
    /// 首筆樣本必定 commit。
    public mutating func ingest(lux: Double, nowMillis: Int64) -> Double? {
        let clamped = max(lux, 0)
        guard let committed = committedValue else {
            committedValue = clamped
            lastCommitMillis = nowMillis
            return clamped
        }
        guard nowMillis - lastCommitMillis >= minIntervalMillis else { return nil }
        let change = abs(log1p(clamped) - log1p(committed))
        guard change >= log1p(relativeThreshold) else { return nil }
        committedValue = clamped
        lastCommitMillis = nowMillis
        return clamped
    }
}
