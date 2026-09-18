import Foundation

/// 鍵盤選區導覽：依正規化矩形的相對位置移動焦點。
public struct ZoneNavigator: Sendable, Equatable {
    public enum Direction: Sendable {
        case left, right, up, down
    }

    public private(set) var zones: [LayoutZone]
    public private(set) var focusedID: String?

    public init(zones: [LayoutZone], focusedID: String? = nil) {
        self.zones = zones
        if let focusedID, zones.contains(where: { $0.id == focusedID }) {
            self.focusedID = focusedID
        } else {
            self.focusedID = Self.defaultFocus(in: zones)
        }
    }

    public mutating func move(_ direction: Direction) {
        guard let currentID = focusedID,
              let current = zones.first(where: { $0.id == currentID }),
              let from = current.normalized
        else { return }

        let candidates = zones.filter { $0.id != currentID && $0.normalized != nil }
        guard !candidates.isEmpty else { return }

        let scored: [(LayoutZone, Double)] = candidates.compactMap { zone in
            guard let to = zone.normalized else { return nil }
            let dx = to.midX - from.midX
            let dy = to.midY - from.midY
            switch direction {
            case .left:
                guard dx < -1e-9 else { return nil }
                return (zone, -dx + abs(dy) * 2)
            case .right:
                guard dx > 1e-9 else { return nil }
                return (zone, dx + abs(dy) * 2)
            case .down:
                // AppKit：y 向上；「下」是較小的 midY
                guard dy < -1e-9 else { return nil }
                return (zone, -dy + abs(dx) * 2)
            case .up:
                guard dy > 1e-9 else { return nil }
                return (zone, dy + abs(dx) * 2)
            }
        }
        guard let best = scored.min(by: { $0.1 < $1.1 }) else { return }
        focusedID = best.0.id
    }

    private static func defaultFocus(in zones: [LayoutZone]) -> String? {
        if let center = zones.first(where: { $0.id == "center" || $0.id == "primary" || $0.id == "reading" }) {
            return center.id
        }
        return zones.first?.id
    }
}

/// 判定分區是否過窄（僅 UX 提示，不禁止選取）。
public enum ZoneWidthHint {
    public static let narrowThreshold: Double = 480

    public static func isNarrow(_ width: Double) -> Bool {
        width > 0 && width < narrowThreshold
    }
}
