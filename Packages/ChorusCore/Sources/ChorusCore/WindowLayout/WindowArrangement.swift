import Foundation

/// 一次排多個視窗的佈局（macOS「填滿與排列」那一類）。第一格給主要視窗，
/// 其餘依序給同螢幕上最近用過的視窗；幾何與單視窗動作共用同一套切法。
public enum WindowArrangement: String, Sendable, Codable, CaseIterable, Hashable {
    /// 左右並排。
    case leftRight
    /// 1 大 2 小：左半全高＋右上、右下。
    case mainLeft
    /// 1 大 2 小的鏡像：右半全高＋左上、左下。
    case mainRight
    /// 三欄等分。
    case threeColumns
    /// 四分。
    case quarters
    // 以下沿用特型版型的分區（三欄已有、中央閱讀只有一區，不重複）；主區排第一格。
    case centerStage
    case fourColumns
    case widePrimary
    case widePrimaryMirrored
    case quarterSide
    case quarterSideMirrored
    case primaryStack
    case primaryStackMirrored

    /// 這個排列沿用哪個特型版型的分區。
    public var templateID: LayoutTemplateID? {
        switch self {
        case .leftRight, .mainLeft, .mainRight, .threeColumns, .quarters: return nil
        case .centerStage: return .centerStage
        case .fourColumns: return .fourColumns
        case .widePrimary: return .widePrimary
        case .widePrimaryMirrored: return .widePrimaryMirrored
        case .quarterSide: return .quarterSide
        case .quarterSideMirrored: return .quarterSideMirrored
        case .primaryStack: return .primaryStack
        case .primaryStackMirrored: return .primaryStackMirrored
        }
    }

    public struct Placement<Window>: Sendable where Window: Sendable {
        public let window: Window
        public let frame: LayoutRect
    }

    /// 單位空間的各格（AppKit 座標，原點左下）；順序＝填入順序，主要視窗第一。
    public var slots: [LayoutRect] {
        if let templateID {
            let zones = LayoutTemplateCatalog.template(id: templateID).zones
            let primaryFirst = zones.filter(\.isPrimary) + zones.filter { !$0.isPrimary }
            return primaryFirst.compactMap(\.normalized)
        }
        switch self {
        case .leftRight:
            return [unit(0, 0, 0.5, 1), unit(0.5, 0, 0.5, 1)]
        case .mainLeft:
            return [unit(0, 0, 0.5, 1), unit(0.5, 0.5, 0.5, 0.5), unit(0.5, 0, 0.5, 0.5)]
        case .mainRight:
            return [unit(0.5, 0, 0.5, 1), unit(0, 0.5, 0.5, 0.5), unit(0, 0, 0.5, 0.5)]
        case .threeColumns:
            return [unit(0, 0, 1.0 / 3, 1), unit(1.0 / 3, 0, 1.0 / 3, 1), unit(2.0 / 3, 0, 1.0 / 3, 1)]
        case .quarters:
            return [
                unit(0, 0.5, 0.5, 0.5), unit(0.5, 0.5, 0.5, 0.5),
                unit(0, 0, 0.5, 0.5), unit(0.5, 0, 0.5, 0.5),
            ]
        default:
            return []
        }
    }

    public var slotCount: Int { slots.count }

    public func frames(visible: LayoutRect, gap: Double) -> [LayoutRect] {
        let g = max(0, gap)
        let zones = slots.enumerated().map { LayoutZone(id: "slot\($0.offset)", nameKey: "", normalized: $0.element) }
        return LayoutTemplate.alignedFrames(zones: zones, inner: visible.insetBy(dx: g, dy: g), gap: g).map(\.1)
    }

    /// 視窗（主要視窗在前）配上各格；視窗不夠就只用前幾格，多的不動。
    public func plan<Window: Sendable>(windows: [Window], visible: LayoutRect, gap: Double) -> [Placement<Window>] {
        zip(windows, frames(visible: visible, gap: gap)).map { Placement(window: $0, frame: $1) }
    }

    private func unit(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> LayoutRect {
        LayoutRect(x: x, y: y, width: w, height: h)
    }
}
