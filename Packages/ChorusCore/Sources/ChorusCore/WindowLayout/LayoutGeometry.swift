import Foundation

/// 邏輯 point 座標的軸對齊矩形（AppKit／可見範圍座標，原點在左下）。
public struct LayoutRect: Sendable, Equatable, Hashable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    public func insetBy(dx: Double, dy: Double) -> LayoutRect {
        LayoutRect(
            x: x + dx,
            y: y + dy,
            width: max(0, width - dx * 2),
            height: max(0, height - dy * 2)
        )
    }

    public func contains(_ pointX: Double, _ pointY: Double) -> Bool {
        pointX >= x && pointX < maxX && pointY >= y && pointY < maxY
    }

    public func intersection(_ other: LayoutRect) -> LayoutRect? {
        let nx = max(x, other.x)
        let ny = max(y, other.y)
        let mx = min(maxX, other.maxX)
        let my = min(maxY, other.maxY)
        guard mx > nx, my > ny else { return nil }
        return LayoutRect(x: nx, y: ny, width: mx - nx, height: my - ny)
    }
}

/// 首版可觸發的排列動作。`ultrawideZone` 需另傳已解析的 zone 矩形。
public enum LayoutAction: String, Sendable, Codable, CaseIterable, Hashable {
    case leftHalf
    case rightHalf
    case topHalf
    case bottomHalf
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight
    case leftThird
    case centerThird
    case rightThird
    case leftTwoThirds
    case centerTwoThirds
    case rightTwoThirds
    case topThird
    case middleThird
    case bottomThird
    case topTwoThirds
    case bottomTwoThirds
    case maximize
    case centerPreserveSize
    case ultrawideZone
}
