import Foundation

/// 邊緣熱區與 Shift 分區候選的純狀態機（不操作真實視窗）。
public struct SnapResolver: Sendable, Equatable {
    public struct ScreenMetrics: Sendable, Equatable {
        public var frame: LayoutRect
        public var isLandscape: Bool

        public init(frame: LayoutRect, isLandscape: Bool) {
            self.frame = frame
            self.isLandscape = isLandscape
        }
    }

    public struct Candidate: Sendable, Equatable {
        public var action: LayoutAction?
        public var zoneID: String?
        public var templateID: LayoutTemplateID?

        public init(action: LayoutAction? = nil, zoneID: String? = nil, templateID: LayoutTemplateID? = nil) {
            self.action = action
            self.zoneID = zoneID
            self.templateID = templateID
        }
    }

    public var edgeThickness: Double
    public var cornerSize: Double

    public init(edgeThickness: Double = 12, cornerSize: Double = 48) {
        self.edgeThickness = edgeThickness
        self.cornerSize = cornerSize
    }

    /// Shift 分區模式：只依命中區回傳 zone；命中區間隙則無候選。
    public func zoneCandidate(
        pointX: Double,
        pointY: Double,
        template: LayoutTemplate,
        visible: LayoutRect,
        gap: Double
    ) -> Candidate? {
        if template.isCenterReading {
            let zones = template.resolvedZones(visible: visible, gap: gap)
            guard let first = zones.first, first.1.contains(pointX, pointY) || containsInclusive(first.1, pointX, pointY) else {
                return nil
            }
            return Candidate(zoneID: first.0.id, templateID: template.id)
        }

        // 命中測試用未退讓內間距前的分區
        let g = max(0, gap)
        let inner = visible.insetBy(dx: g, dy: g)
        for zone in template.zones {
            guard let n = zone.normalized else { continue }
            let raw = LayoutRect(
                x: inner.x + inner.width * n.x,
                y: inner.y + inner.height * n.y,
                width: inner.width * n.width,
                height: inner.height * n.height
            )
            if containsHalfOpen(raw, pointX, pointY, isLastX: n.x + n.width >= 1 - 1e-12, isLastY: n.y + n.height >= 1 - 1e-12) {
                return Candidate(zoneID: zone.id, templateID: template.id)
            }
        }
        return nil
    }

    /// 邊緣熱區（橫向螢幕）。角落優先於邊緣。
    public func edgeCandidate(pointX: Double, pointY: Double, screen: ScreenMetrics) -> Candidate? {
        let f = screen.frame
        let onLeft = pointX <= f.x + edgeThickness
        let onRight = pointX >= f.maxX - edgeThickness
        let onBottom = pointY <= f.y + edgeThickness
        let onTop = pointY >= f.maxY - edgeThickness

        let nearLeft = pointX <= f.x + cornerSize
        let nearRight = pointX >= f.maxX - cornerSize
        let nearBottom = pointY <= f.y + cornerSize
        let nearTop = pointY >= f.maxY - cornerSize

        if nearLeft && nearTop { return Candidate(action: .topLeft) }
        if nearRight && nearTop { return Candidate(action: .topRight) }
        if nearLeft && nearBottom { return Candidate(action: .bottomLeft) }
        if nearRight && nearBottom { return Candidate(action: .bottomRight) }

        if onLeft { return Candidate(action: .leftHalf) }
        if onRight { return Candidate(action: .rightHalf) }
        if onTop { return Candidate(action: .maximize) }

        if onBottom && screen.isLandscape {
            let usableLeft = f.x + cornerSize
            let usableRight = f.maxX - cornerSize
            let width = max(1, usableRight - usableLeft)
            let t = (pointX - usableLeft) / width
            if t < 0.2 { return Candidate(action: .leftThird) }
            if t < 0.4 { return Candidate(action: .leftTwoThirds) }
            if t < 0.6 { return Candidate(action: .centerThird) }
            if t < 0.8 { return Candidate(action: .rightTwoThirds) }
            return Candidate(action: .rightThird)
        }

        return nil
    }

    private func containsHalfOpen(_ rect: LayoutRect, _ x: Double, _ y: Double, isLastX: Bool, isLastY: Bool) -> Bool {
        let xOK = isLastX ? (x >= rect.x && x <= rect.maxX) : (x >= rect.x && x < rect.maxX)
        let yOK = isLastY ? (y >= rect.y && y <= rect.maxY) : (y >= rect.y && y < rect.maxY)
        return xOK && yOK
    }

    private func containsInclusive(_ rect: LayoutRect, _ x: Double, _ y: Double) -> Bool {
        x >= rect.x && x <= rect.maxX && y >= rect.y && y <= rect.maxY
    }
}
