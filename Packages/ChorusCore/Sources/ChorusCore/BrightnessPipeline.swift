import Foundation

/// 把單一 0–1 slider 值映射成「硬體亮度 + 軟體調光係數」。
///
/// - `softwareThreshold == 0`：純硬體模式，slider 直接對應硬體亮度。
/// - `softwareThreshold > 0`：combined dimming — slider 高於門檻走硬體、
///   低於門檻時硬體降到 0、改用 gamma 軟體調光繼續變暗。
/// - 沒有硬體控制的顯示器（`hasHardwareControl == false`）一律走軟體調光。
public struct BrightnessPipeline: Sendable, Equatable {
    /// slider 低於此值改用軟體調光（0 表示停用 combined dimming）。
    public var softwareThreshold: Double
    /// 軟體調光的最低係數（避免全黑）。
    public var minimumSoftwareFactor: Double

    public init(softwareThreshold: Double = 0, minimumSoftwareFactor: Double = 0.15) {
        self.softwareThreshold = min(max(softwareThreshold, 0), 0.9)
        self.minimumSoftwareFactor = min(max(minimumSoftwareFactor, 0.05), 1)
    }

    public struct Output: Equatable, Sendable {
        /// 0–1 的硬體亮度；nil 表示這個顯示器不做硬體控制。
        public let hardware: Double?
        /// 1 表示不做軟體調光。
        public let softwareFactor: Double

        public init(hardware: Double?, softwareFactor: Double) {
            self.hardware = hardware
            self.softwareFactor = softwareFactor
        }
    }

    /// `map` 的反函數（硬體亮度 → slider 值）：重啟時把讀到的硬體現值還原成
    /// 滑桿位置。硬體 0 對應整段軟體調光區間、無法唯一還原 → 回 nil
    /// （呼叫端改用上次記住的滑桿值）。
    public func sliderValue(forHardware hardware: Double) -> Double? {
        let value = min(max(hardware, 0), 1)
        guard softwareThreshold > 0 else { return value }
        guard value > 0 else { return nil }
        return softwareThreshold + value * (1 - softwareThreshold)
    }

    public func map(slider: Double, hasHardwareControl: Bool) -> Output {
        let value = min(max(slider, 0), 1)

        guard hasHardwareControl else {
            let factor = minimumSoftwareFactor + (1 - minimumSoftwareFactor) * value
            return Output(hardware: nil, softwareFactor: factor)
        }

        guard softwareThreshold > 0 else {
            return Output(hardware: value, softwareFactor: 1)
        }

        if value >= softwareThreshold {
            let hardware = (value - softwareThreshold) / (1 - softwareThreshold)
            return Output(hardware: hardware, softwareFactor: 1)
        } else {
            let factor = minimumSoftwareFactor + (1 - minimumSoftwareFactor) * (value / softwareThreshold)
            return Output(hardware: 0, softwareFactor: factor)
        }
    }
}
