import Foundation

/// 選單列圖示的幾何——沿用 Status Trio 的排法：外圈一道從左下掃到右下的主弧
/// （這裡是音量——比亮度常調，給它最長、解析度最高的那道），頂端可以打開一個
/// 開口放數字；底部沿同一個圓再畫一小段（這裡是亮度）。常數以位置命名，
/// 哪個量畫在哪道弧由繪製端決定。座標與角度都以 Status Trio 的 120 單位畫布為準，
/// 角度用 SVG 慣例（y 往下、順時針為正）；繪製端負責換算成 pt 與 CoreGraphics。
///
/// 純數學、不碰 CoreGraphics，讓「哪裡該畫、哪裡該留白」能單獨測。
public enum StatusIconGeometry {
    /// 畫布邊長（Status Trio 的 120 單位）。
    public static let canvas: Double = 120
    public static let ringCenterX: Double = 59.5
    public static let ringCenterY: Double = 61.487_152_617_854_73
    public static let ringRadius: Double = 51.5
    /// 環的線寬（畫布單位）。
    public static let ringLineWidth: Double = 8

    /// 主弧：從左下 148.69° 順時針掃 242.62° 到右下（SVG 角度）。
    public static let mainArcStart: Double = 148.690_086_892_811_17 * .pi / 180
    public static let mainArcSweep: Double = 242.619_826_214_377_7 * .pi / 180

    /// 底弧：底部 121.82° → 59.12°（SVG 角度），與主弧兩端各留一小段空隙。
    public static let bottomArcStart: Double = 121.82 * .pi / 180
    public static let bottomArcEnd: Double = 59.12 * .pi / 180

    /// 開口最多吃掉六成——再多，弧兩端就只剩短短兩截，看不出是同一個環。
    public static let maxGapFraction: Double = 0.6

    /// 弧上的一段，以進度（0…1，沿掃角方向）表示。
    public struct ArcSegment: Equatable, Sendable {
        public var from: Double
        public var to: Double

        public init(from: Double, to: Double) {
            self.from = from
            self.to = to
        }
    }

    /// 主弧要畫的段落：進度 `progress` 之內、扣掉置中在頂端（進度 0.5）
    /// 寬 `gapFraction` 的開口。沒開口就是一段；進度落在開口裡就停在開口起點；
    /// 越過開口則兩段。
    public static func arcSegments(progress: Double, gapFraction: Double) -> [ArcSegment] {
        let progress = min(max(progress, 0), 1)
        let gap = min(max(gapFraction, 0), maxGapFraction)
        guard progress > 0 else { return [] }
        guard gap > 0 else { return [ArcSegment(from: 0, to: progress)] }

        let gapStart = 0.5 - gap / 2
        let gapEnd = 0.5 + gap / 2
        var segments = [ArcSegment(from: 0, to: min(progress, gapStart))]
        if progress > gapEnd {
            segments.append(ArcSegment(from: gapEnd, to: progress))
        }
        return segments
    }

    /// 開口寬度：內容寬加兩側留白，換算成整段弧長的比例。
    public static func gapFraction(contentWidth: Double, padding: Double, radius: Double) -> Double {
        let arcLength = radius * mainArcSweep
        guard arcLength > 0 else { return 0 }
        return max(0, (contentWidth + padding * 2) / arcLength)
    }

    /// 音量弧的比例。靜音、沒裝置、零音量都只剩軌道（回 nil）。
    public static func volumeArcProgress(volume: Double?, muted: Bool) -> Double? {
        guard !muted, let volume, volume > 0.001 else { return nil }
        return min(volume, 1)
    }

    /// 亮度弧的比例。讀不到亮度或全暗都只剩軌道（回 nil）。
    public static func brightnessArcProgress(brightness: Double?) -> Double? {
        guard let brightness, brightness > 0.001 else { return nil }
        return min(brightness, 1)
    }

    /// 兩道弧各自要點亮的比例；`nil`＝只剩軌道。
    public struct Arcs: Equatable, Sendable {
        public var main: Double?
        public var bottom: Double?

        public init(main: Double?, bottom: Double?) {
            self.main = main
            self.bottom = bottom
        }
    }

    /// 哪個量畫在哪道弧。平常主弧＝音量、底弧＝亮度。
    ///
    /// 有讀數時，主弧改畫**讀數本身**——數字就開在主弧頂端，兩者講的必須是同一件事
    /// （調的若不是主顯示器，圖示平常讀的亮度還跟數字對不上，所以用讀數的值而不是狀態值）。
    /// 調亮度那一下，音量暫時換到底弧，讀數收掉再換回來。
    public static func arcs(
        brightness: Double?,
        volume: Double?,
        muted: Bool,
        readout: StatusReadout?
    ) -> Arcs {
        let volumeArc = volumeArcProgress(volume: volume, muted: muted)
        let brightnessArc = brightnessArcProgress(brightness: brightness)
        guard let readout else { return Arcs(main: volumeArc, bottom: brightnessArc) }

        let value = Double(readout.percent) / 100
        let main = value > 0.001 ? value : nil
        switch readout.kind {
        case .volume: return Arcs(main: main, bottom: brightnessArc)
        case .brightness: return Arcs(main: main, bottom: volumeArc)
        }
    }
}
