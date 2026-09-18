import AppKit
import ChorusCore
import CoreGraphics

/// 螢幕幾何快照：統一 AppKit（左下原點）與 AX／CG（主螢幕左上原點）轉換。
struct ScreenTopology: Sendable {
    struct ScreenInfo: Sendable, Equatable {
        var displayUUID: String
        var displayID: CGDirectDisplayID
        /// 系統給的裝置名稱（「ASUS VS207」「內建 Retina 顯示器」），介面上用它指認螢幕。
        var name: String
        var frame: LayoutRect
        var visibleFrame: LayoutRect
        var isLandscape: Bool

        /// 以完整邏輯 frame 的寬高比判定；不是超寬就不提供超寬版型。
        var isUltrawide: Bool {
            LayoutTemplateCatalog.isUltrawide(width: frame.width, height: frame.height)
        }
    }

    var generation: UInt64
    var screens: [ScreenInfo]
    /// 主螢幕高度（CG 座標轉換用）。
    var primaryHeight: Double

    static func capture(generation: UInt64) -> ScreenTopology {
        let primaryHeight = Double(CGDisplayBounds(CGMainDisplayID()).height)
        let screens: [ScreenInfo] = NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let displayID = CGDirectDisplayID(number.uint32Value)
            let frame = LayoutRect(cgRect: screen.frame)
            let visible = LayoutRect(cgRect: screen.visibleFrame)
            return ScreenInfo(
                displayUUID: Self.stableUUID(for: displayID),
                displayID: displayID,
                name: screen.localizedName,
                frame: frame,
                visibleFrame: visible,
                isLandscape: frame.width >= frame.height
            )
        }
        return ScreenTopology(generation: generation, screens: screens, primaryHeight: primaryHeight)
    }

    func screen(containing rect: LayoutRect) -> ScreenInfo? {
        screens.max { a, b in
            area(a.visibleFrame.intersection(rect)) < area(b.visibleFrame.intersection(rect))
        }
    }

    func screen(containingPointX x: Double, y: Double) -> ScreenInfo? {
        screens.first { $0.frame.contains(x, y) || containsInclusive($0.frame, x, y) }
    }

    func screen(uuid: String) -> ScreenInfo? {
        screens.first { $0.displayUUID == uuid }
    }

    /// AppKit（左下）→ AX（主螢幕左上、Y 向下）。
    func toAX(_ rect: LayoutRect) -> (origin: CGPoint, size: CGSize) {
        let origin = CGPoint(x: rect.x, y: primaryHeight - rect.maxY)
        let size = CGSize(width: rect.width, height: rect.height)
        return (origin, size)
    }

    /// AX → AppKit。
    func fromAX(origin: CGPoint, size: CGSize) -> LayoutRect {
        LayoutRect(
            x: Double(origin.x),
            y: primaryHeight - Double(origin.y) - Double(size.height),
            width: Double(size.width),
            height: Double(size.height)
        )
    }

    private func area(_ rect: LayoutRect?) -> Double {
        guard let rect else { return 0 }
        return rect.width * rect.height
    }

    private func containsInclusive(_ rect: LayoutRect, _ x: Double, _ y: Double) -> Bool {
        x >= rect.x && x <= rect.maxX && y >= rect.y && y <= rect.maxY
    }

    static func stableUUID(for id: CGDirectDisplayID) -> String {
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuidRef) as String
        }
        return "display-\(id)"
    }
}

extension LayoutRect {
    init(cgRect: CGRect) {
        self.init(
            x: Double(cgRect.origin.x),
            y: Double(cgRect.origin.y),
            width: Double(cgRect.size.width),
            height: Double(cgRect.size.height)
        )
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
