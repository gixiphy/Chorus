import Foundation

public struct LayoutSize: Sendable, Equatable, Hashable, Codable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// 只用於排名，不是 App 最小寬度。
    public static let comfortable = LayoutSize(width: 480, height: 360)

    public func fits(in rect: LayoutRect, tolerance: Double = 2) -> Bool {
        width <= rect.width + tolerance && height <= rect.height + tolerance
    }
}

/// 以 token 為鍵的最小尺寸下限（記憶體）。未知軸存 0；整體 nil＝完全未知。
public struct WindowSizeHints: Sendable, Equatable {
    private var minima: [String: LayoutSize]

    public init(minima: [String: LayoutSize] = [:]) {
        self.minima = minima
    }

    public func minimumSize(for token: String) -> LayoutSize? {
        minima[token]
    }

    /// 讀回比要求大 > tolerance 的軸，讀回值成為該軸下限；沒受限的軸不記。
    public mutating func recordReadBack(
        token: String,
        requested: LayoutRect,
        actual: LayoutRect,
        tolerance: Double = 2
    ) {
        var widthBound: Double = 0
        var heightBound: Double = 0
        if actual.width - requested.width > tolerance {
            widthBound = actual.width
        }
        if actual.height - requested.height > tolerance {
            heightBound = actual.height
        }
        guard widthBound > 0 || heightBound > 0 else { return }
        merge(token: token, LayoutSize(width: widthBound, height: heightBound))
    }

    /// 其他來源回報的最小尺寸；與既有下限取 max。
    public mutating func recordReported(token: String, minimum: LayoutSize) {
        merge(token: token, minimum)
    }

    public mutating func forget(token: String) {
        minima.removeValue(forKey: token)
    }

    public mutating func removeAll() {
        minima.removeAll()
    }

    private mutating func merge(token: String, _ size: LayoutSize) {
        if let existing = minima[token] {
            minima[token] = LayoutSize(
                width: max(existing.width, size.width),
                height: max(existing.height, size.height)
            )
        } else {
            minima[token] = size
        }
    }
}
