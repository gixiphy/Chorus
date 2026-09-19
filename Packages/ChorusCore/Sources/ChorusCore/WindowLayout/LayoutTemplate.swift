import Foundation

public enum LayoutTemplateID: String, Sendable, Codable, CaseIterable, Hashable {
    case centerStage
    case threeColumns
    case fourColumns
    case widePrimary
    case widePrimaryMirrored
    /// 側欄 1/4 在左、主區 3/4 在右。
    case quarterSide
    /// 主區 3/4 在左、側欄 1/4 在右。
    case quarterSideMirrored
    case primaryStack
    case primaryStackMirrored
    case centerReading
}

public struct LayoutZone: Sendable, Equatable, Identifiable, Hashable {
    public let id: String
    /// 語意名稱鍵（UI／VoiceOver 對照），不是本地化字串本身。
    public let nameKey: String
    /// 單位空間 0…1 的正規化矩形；`centerReading` 不使用此欄，改走策略。
    public let normalized: LayoutRect?

    public init(id: String, nameKey: String, normalized: LayoutRect?) {
        self.id = id
        self.nameKey = nameKey
        self.normalized = normalized
    }

    /// 版型裡的主要工作區（中央主區／主區）；均分版型沒有。
    public var isPrimary: Bool { id == "center" || id == "primary" }
}

public struct LayoutTemplate: Sendable, Equatable {
    public let id: LayoutTemplateID
    public let zones: [LayoutZone]
    public let isCenterReading: Bool

    public init(id: LayoutTemplateID, zones: [LayoutZone], isCenterReading: Bool = false) {
        self.id = id
        self.zones = zones
        self.isCenterReading = isCenterReading
    }

    /// 回傳 (zone, 已扣間距的目標矩形)。
    public func resolvedZones(visible: LayoutRect, gap: Double) -> [(LayoutZone, LayoutRect)] {
        let g = max(0, gap)
        let inner = visible.insetBy(dx: g, dy: g)
        if isCenterReading {
            let zone = zones[0]
            let w = min(inner.width, inner.height * 16.0 / 9.0)
            let rect = LayoutRect(
                x: inner.x + (inner.width - w) / 2,
                y: inner.y,
                width: w,
                height: inner.height
            )
            return [(zone, rect)]
        }

        return Self.alignedFrames(zones: zones, inner: inner, gap: g)
    }

    /// 一組正規化分區 → 像素對齊、共用邊各退 gap/2 的矩形。版型與多視窗排列共用。
    static func alignedFrames(zones: [LayoutZone], inner: LayoutRect, gap g: Double) -> [(LayoutZone, LayoutRect)] {
        let engine = LayoutEngine()
        return zones.compactMap { zone in
            guard let n = zone.normalized else { return nil }
            let raw = LayoutRect(
                x: inner.x + inner.width * n.x,
                y: inner.y + inner.height * n.y,
                width: inner.width * n.width,
                height: inner.height * n.height
            )
            // 以像素對齊邊界表重建，避免浮點漂移；再用 gap 退讓共用邊
            let rect = resolveAligned(zone: zone, all: zones, inner: inner, gap: g, engine: engine, fallback: raw)
            return (zone, rect)
        }
    }

    private static func resolveAligned(
        zone: LayoutZone,
        all: [LayoutZone],
        inner: LayoutRect,
        gap: Double,
        engine: LayoutEngine,
        fallback: LayoutRect
    ) -> LayoutRect {
        guard let n = zone.normalized else { return fallback }
        // 收集水平／垂直切點
        var xFrac: [Double] = [0, 1]
        var yFrac: [Double] = [0, 1]
        for z in all {
            guard let zn = z.normalized else { continue }
            xFrac.append(zn.x)
            xFrac.append(zn.x + zn.width)
            yFrac.append(zn.y)
            yFrac.append(zn.y + zn.height)
        }
        let xCuts = engine.pixelCuts(origin: inner.x, length: inner.width, fractions: xFrac)
        let yCuts = engine.pixelCuts(origin: inner.y, length: inner.height, fractions: yFrac)
        let xSorted = uniqueSorted(xFrac)
        let ySorted = uniqueSorted(yFrac)
        guard let xi0 = nearestIndex(n.x, in: xSorted),
              let xi1 = nearestIndex(n.x + n.width, in: xSorted),
              let yi0 = nearestIndex(n.y, in: ySorted),
              let yi1 = nearestIndex(n.y + n.height, in: ySorted)
        else {
            return fallback
        }
        var x0 = xCuts[xi0]
        var x1 = xCuts[xi1]
        var y0 = yCuts[yi0]
        var y1 = yCuts[yi1]
        if n.x > 0 { x0 += gap / 2 }
        if n.x + n.width < 1 { x1 -= gap / 2 }
        if n.y > 0 { y0 += gap / 2 }
        if n.y + n.height < 1 { y1 -= gap / 2 }
        return LayoutRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
}

public enum LayoutTemplateCatalog {
    public static func template(id: LayoutTemplateID) -> LayoutTemplate {
        switch id {
        case .centerStage:
            return LayoutTemplate(id: id, zones: [
                zone("left", "ultrawide.left", x: 0, y: 0, w: 0.25, h: 1),
                zone("center", "ultrawide.center", x: 0.25, y: 0, w: 0.5, h: 1),
                zone("right", "ultrawide.right", x: 0.75, y: 0, w: 0.25, h: 1),
            ])
        case .threeColumns:
            return LayoutTemplate(id: id, zones: [
                zone("col1", "ultrawide.col1", x: 0, y: 0, w: 1.0 / 3.0, h: 1),
                zone("col2", "ultrawide.col2", x: 1.0 / 3.0, y: 0, w: 1.0 / 3.0, h: 1),
                zone("col3", "ultrawide.col3", x: 2.0 / 3.0, y: 0, w: 1.0 / 3.0, h: 1),
            ])
        case .fourColumns:
            return LayoutTemplate(id: id, zones: [
                zone("col1", "ultrawide.col1", x: 0, y: 0, w: 0.25, h: 1),
                zone("col2", "ultrawide.col2", x: 0.25, y: 0, w: 0.25, h: 1),
                zone("col3", "ultrawide.col3", x: 0.5, y: 0, w: 0.25, h: 1),
                zone("col4", "ultrawide.col4", x: 0.75, y: 0, w: 0.25, h: 1),
            ])
        case .widePrimary:
            return LayoutTemplate(id: id, zones: [
                zone("primary", "ultrawide.primary", x: 0, y: 0, w: 2.0 / 3.0, h: 1),
                zone("side", "ultrawide.side", x: 2.0 / 3.0, y: 0, w: 1.0 / 3.0, h: 1),
            ])
        case .widePrimaryMirrored:
            return LayoutTemplate(id: id, zones: [
                zone("side", "ultrawide.side", x: 0, y: 0, w: 1.0 / 3.0, h: 1),
                zone("primary", "ultrawide.primary", x: 1.0 / 3.0, y: 0, w: 2.0 / 3.0, h: 1),
            ])
        case .quarterSide:
            return LayoutTemplate(id: id, zones: [
                zone("side", "ultrawide.side", x: 0, y: 0, w: 0.25, h: 1),
                zone("primary", "ultrawide.primary", x: 0.25, y: 0, w: 0.75, h: 1),
            ])
        case .quarterSideMirrored:
            return LayoutTemplate(id: id, zones: [
                zone("primary", "ultrawide.primary", x: 0, y: 0, w: 0.75, h: 1),
                zone("side", "ultrawide.side", x: 0.75, y: 0, w: 0.25, h: 1),
            ])
        case .primaryStack:
            return LayoutTemplate(id: id, zones: [
                zone("primary", "ultrawide.primary", x: 0, y: 0, w: 2.0 / 3.0, h: 1),
                zone("sideTop", "ultrawide.sideTop", x: 2.0 / 3.0, y: 0.5, w: 1.0 / 3.0, h: 0.5),
                zone("sideBottom", "ultrawide.sideBottom", x: 2.0 / 3.0, y: 0, w: 1.0 / 3.0, h: 0.5),
            ])
        case .primaryStackMirrored:
            return LayoutTemplate(id: id, zones: [
                zone("sideTop", "ultrawide.sideTop", x: 0, y: 0.5, w: 1.0 / 3.0, h: 0.5),
                zone("sideBottom", "ultrawide.sideBottom", x: 0, y: 0, w: 1.0 / 3.0, h: 0.5),
                zone("primary", "ultrawide.primary", x: 1.0 / 3.0, y: 0, w: 2.0 / 3.0, h: 1),
            ])
        case .centerReading:
            return LayoutTemplate(
                id: id,
                zones: [LayoutZone(id: "reading", nameKey: "ultrawide.reading", normalized: nil)],
                isCenterReading: true
            )
        }
    }

    /// 算作超寬的寬高比下限（21:9 類約 2.33 起）；只影響預設推薦，版型每台橫向螢幕都能選。
    public static let ultrawideMinimumAspectRatio = 2.2

    public static func isUltrawide(width: Double, height: Double) -> Bool {
        guard height > 0 else { return false }
        return width / height >= ultrawideMinimumAspectRatio
    }

    /// 21:9／32:9 類以中央主區為初始推薦；一般比例切三區太窄，改給主副欄（2/3＋1/3）。
    public static func recommended(aspectRatio: Double) -> LayoutTemplateID {
        aspectRatio >= ultrawideMinimumAspectRatio ? .centerStage : .widePrimary
    }

    public static func secondaryRecommendation(aspectRatio: Double) -> LayoutTemplateID {
        if aspectRatio >= 3.2 { return .fourColumns }
        return .threeColumns
    }

    private static func zone(_ id: String, _ nameKey: String, x: Double, y: Double, w: Double, h: Double) -> LayoutZone {
        LayoutZone(id: id, nameKey: nameKey, normalized: LayoutRect(x: x, y: y, width: w, height: h))
    }
}

private func uniqueSorted(_ values: [Double]) -> [Double] {
    var result: [Double] = []
    for value in values.sorted() {
        if let last = result.last, abs(last - value) < 1e-12 { continue }
        result.append(value)
    }
    return result
}

private func nearestIndex(_ value: Double, in fractions: [Double]) -> Int? {
    fractions.firstIndex { abs($0 - value) < 1e-9 }
}
