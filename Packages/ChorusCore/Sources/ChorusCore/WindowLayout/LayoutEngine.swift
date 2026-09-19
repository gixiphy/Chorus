import Foundation

/// 依可見範圍與間距計算目標視窗矩形。無 AppKit／AX 相依。
public struct LayoutEngine: Sendable, Equatable {
    public init() {}

    public func frame(
        for action: LayoutAction,
        visible: LayoutRect,
        gap: Double,
        current: LayoutRect? = nil,
        zone: LayoutRect? = nil
    ) -> LayoutRect {
        let g = max(0, gap)
        let inner = visible.insetBy(dx: g, dy: g)

        switch action {
        case .leftHalf:
            return horizontalSlice(inner: inner, gap: g, startFraction: 0, endFraction: 0.5)
        case .rightHalf:
            return horizontalSlice(inner: inner, gap: g, startFraction: 0.5, endFraction: 1)
        case .topHalf:
            return verticalSlice(inner: inner, gap: g, startFraction: 0.5, endFraction: 1)
        case .bottomHalf:
            return verticalSlice(inner: inner, gap: g, startFraction: 0, endFraction: 0.5)
        case .topLeft:
            return corner(inner: inner, gap: g, horizontal: 0, vertical: 1)
        case .topRight:
            return corner(inner: inner, gap: g, horizontal: 1, vertical: 1)
        case .bottomLeft:
            return corner(inner: inner, gap: g, horizontal: 0, vertical: 0)
        case .bottomRight:
            return corner(inner: inner, gap: g, horizontal: 1, vertical: 0)
        case .leftThird:
            return horizontalSlice(inner: inner, gap: g, startFraction: 0, endFraction: 1.0 / 3.0)
        case .centerThird:
            return horizontalSlice(inner: inner, gap: g, startFraction: 1.0 / 3.0, endFraction: 2.0 / 3.0)
        case .rightThird:
            return horizontalSlice(inner: inner, gap: g, startFraction: 2.0 / 3.0, endFraction: 1)
        case .leftTwoThirds:
            return horizontalSlice(inner: inner, gap: g, startFraction: 0, endFraction: 2.0 / 3.0)
        case .centerTwoThirds:
            // 獨立目標矩形：兩側 1/6 是留白而非可選分區，所以不退 gap/2。
            // 兩側用同一個取整量，非整除寬度仍對稱
            let margin = floor(inner.width / 6)
            return LayoutRect(
                x: inner.x + margin,
                y: inner.y,
                width: max(0, inner.width - margin * 2),
                height: inner.height
            )
        case .rightTwoThirds:
            return horizontalSlice(inner: inner, gap: g, startFraction: 1.0 / 3.0, endFraction: 1)
        case .firstFourth:
            return horizontalSlice(inner: inner, gap: g, startFraction: 0, endFraction: 0.25)
        case .secondFourth:
            return horizontalSlice(inner: inner, gap: g, startFraction: 0.25, endFraction: 0.5)
        case .thirdFourth:
            return horizontalSlice(inner: inner, gap: g, startFraction: 0.5, endFraction: 0.75)
        case .lastFourth:
            return horizontalSlice(inner: inner, gap: g, startFraction: 0.75, endFraction: 1)
        case .leftThreeFourths:
            return horizontalSlice(inner: inner, gap: g, startFraction: 0, endFraction: 0.75)
        case .rightThreeFourths:
            return horizontalSlice(inner: inner, gap: g, startFraction: 0.25, endFraction: 1)
        case .topThird:
            return verticalSlice(inner: inner, gap: g, startFraction: 2.0 / 3.0, endFraction: 1)
        case .middleThird:
            return verticalSlice(inner: inner, gap: g, startFraction: 1.0 / 3.0, endFraction: 2.0 / 3.0)
        case .bottomThird:
            return verticalSlice(inner: inner, gap: g, startFraction: 0, endFraction: 1.0 / 3.0)
        case .topTwoThirds:
            return verticalSlice(inner: inner, gap: g, startFraction: 1.0 / 3.0, endFraction: 1)
        case .bottomTwoThirds:
            return verticalSlice(inner: inner, gap: g, startFraction: 0, endFraction: 2.0 / 3.0)
        case .maximize:
            return inner
        case .centerPreserveSize:
            let size = current ?? LayoutRect(x: 0, y: 0, width: min(inner.width, 800), height: min(inner.height, 600))
            let w = min(size.width, inner.width)
            let h = min(size.height, inner.height)
            return LayoutRect(
                x: inner.x + (inner.width - w) / 2,
                y: inner.y + (inner.height - h) / 2,
                width: w,
                height: h
            )
        case .ultrawideZone:
            return zone ?? inner
        }
    }

    /// 以單位區間 `[start, end]` 切水平區。尾端吸收非整除餘數；與鄰區共用邊各退 `gap/2`。
    public func horizontalSlice(
        inner: LayoutRect,
        gap: Double,
        startFraction: Double,
        endFraction: Double
    ) -> LayoutRect {
        let fractions = [0, startFraction, endFraction, 1].uniquedSorted()
        let cuts = pixelCuts(origin: inner.x, length: inner.width, fractions: fractions)
        guard let i0 = indexOfFraction(startFraction, in: fractions),
              let i1 = indexOfFraction(endFraction, in: fractions)
        else {
            return inner
        }
        var x0 = cuts[i0]
        var x1 = cuts[i1]
        if startFraction > 0 { x0 += gap / 2 }
        if endFraction < 1 { x1 -= gap / 2 }
        return LayoutRect(x: x0, y: inner.y, width: max(0, x1 - x0), height: inner.height)
    }

    public func verticalSlice(
        inner: LayoutRect,
        gap: Double,
        startFraction: Double,
        endFraction: Double
    ) -> LayoutRect {
        let fractions = [0, startFraction, endFraction, 1].uniquedSorted()
        let cuts = pixelCuts(origin: inner.y, length: inner.height, fractions: fractions)
        guard let i0 = indexOfFraction(startFraction, in: fractions),
              let i1 = indexOfFraction(endFraction, in: fractions)
        else {
            return inner
        }
        var y0 = cuts[i0]
        var y1 = cuts[i1]
        if startFraction > 0 { y0 += gap / 2 }
        if endFraction < 1 { y1 -= gap / 2 }
        return LayoutRect(x: inner.x, y: y0, width: inner.width, height: max(0, y1 - y0))
    }

    private func corner(inner: LayoutRect, gap: Double, horizontal: Int, vertical: Int) -> LayoutRect {
        let hStart = horizontal == 0 ? 0.0 : 0.5
        let hEnd = horizontal == 0 ? 0.5 : 1.0
        let vStart = vertical == 0 ? 0.0 : 0.5
        let vEnd = vertical == 0 ? 0.5 : 1.0
        let h = horizontalSlice(inner: inner, gap: gap, startFraction: hStart, endFraction: hEnd)
        let v = verticalSlice(inner: inner, gap: gap, startFraction: vStart, endFraction: vEnd)
        return LayoutRect(x: h.x, y: v.y, width: h.width, height: v.height)
    }

    /// 把單位切點對應到像素；最後一段吸收餘數，避免縫隙累積。
    public func pixelCuts(origin: Double, length: Double, fractions: [Double]) -> [Double] {
        let sorted = fractions.uniquedSorted()
        var cuts: [Double] = []
        cuts.reserveCapacity(sorted.count)
        for (i, f) in sorted.enumerated() {
            if i == sorted.count - 1 {
                cuts.append(origin + length)
            } else {
                cuts.append(origin + floor(length * f))
            }
        }
        for i in 1..<cuts.count where cuts[i] < cuts[i - 1] {
            cuts[i] = cuts[i - 1]
        }
        return cuts
    }

    private func indexOfFraction(_ value: Double, in fractions: [Double]) -> Int? {
        fractions.firstIndex { abs($0 - value) < 1e-12 }
    }
}

private extension Array where Element == Double {
    func uniquedSorted() -> [Double] {
        var result: [Double] = []
        for value in sorted() {
            if let last = result.last, abs(last - value) < 1e-12 { continue }
            result.append(value)
        }
        return result
    }
}
