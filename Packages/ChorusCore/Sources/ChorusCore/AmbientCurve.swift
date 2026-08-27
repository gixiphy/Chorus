import Foundation

/// 環境光（lux）→ 亮度 slider 值（0–1）的映射曲線。
/// 對數形：人眼對亮度感知近似對數，低照度區間變化較敏感。
/// 純邏輯、可序列化（使用者可調參數會持久化）。
public struct AmbientCurve: Codable, Sendable, Equatable {
    /// 0 lx 時的亮度下限。
    public var minBrightness: Double
    /// 達到全亮（1.0）所需的環境光。不同硬體 lux 刻度不一致，由此參數吸收。
    public var maxLux: Double

    public init(minBrightness: Double = 0.15, maxLux: Double = 1200) {
        self.minBrightness = min(max(minBrightness, 0), 1)
        self.maxLux = max(maxLux, 1)
    }

    /// lux → 亮度，單調遞增、夾在 minBrightness…1。
    public func map(lux: Double) -> Double {
        let clampedLux = min(max(lux, 0), maxLux)
        let fraction = log1p(clampedLux) / log1p(maxLux)
        return minBrightness + (1 - minBrightness) * fraction
    }

    /// 基準亮度疊加該顯示器差異值與整機差異值，夾回 0…1。
    public static func applyOffsets(base: Double, displayOffset: Double, deviceOffset: Double) -> Double {
        min(max(base + displayOffset + deviceOffset, 0), 1)
    }
}
