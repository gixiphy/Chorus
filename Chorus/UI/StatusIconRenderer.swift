import AppKit
import ChorusCore

/// 選單列圖示的繪製。
///
/// 一張 template image：**只有 alpha 有意義**，顏色由系統決定——
/// 這樣淺色／深色選單列、以及選單被點開時的反白全部自動正確，
/// 不必自己追蹤 appearance。
///
/// 版面：外環（開口朝下的 270° gauge）＝主要顯示器亮度；中心三根聲波柱
/// ＝預設輸出音量，靜音時塌成一條橫線；右側文字＝防睡眠或限時場景的倒數
/// （兩個都沒在跑就不畫，圖示也就窄一格）。
enum StatusIconRenderer {
    /// 選單列圖示的標準邊長。NSStatusItem 高 22pt，18pt 是留白後的可用範圍。
    static let side: CGFloat = 18
    /// computed 而非 stored：stored 的話是個非 Sendable 的 static，
    /// 但繪製會在非 main actor 的 drawingHandler 裡跑。NSFont 本身不可變，
    /// 每次取用實際上走的是系統的字型快取。
    private static var badgeFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
    /// 圖示與文字之間的間距。
    private static let badgeGap: CGFloat = 3

    /// 量化過的 state → template image。相同 state 直接回上一張，
    /// 免得倒數期間每秒重新配置點陣圖。
    @MainActor private static var cache: (state: StatusIconState, image: NSImage)?

    @MainActor
    static func image(for state: StatusIconState) -> NSImage {
        if let cache, cache.state == state { return cache.image }
        let rendered = render(state)
        cache = (state, rendered)
        return rendered
    }

    private static func render(_ state: StatusIconState) -> NSImage {
        let badgeWidth = state.badge.map { reservedWidth(forBadge: $0.text) } ?? 0
        let totalWidth = side + (badgeWidth > 0 ? badgeGap + badgeWidth : 0)
        // drawingHandler 會在每個 scale 各呼叫一次，換螢幕（1x↔2x）時自動重畫
        let image = NSImage(size: NSSize(width: totalWidth, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, in: context, badgeWidth: badgeWidth)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(state)
        return image
    }

    // MARK: - 繪製

    private static func draw(_ state: StatusIconState, in context: CGContext, badgeWidth: CGFloat) {
        let center = CGPoint(x: side / 2, y: side / 2)
        context.setStrokeColor(NSColor.black.cgColor)
        context.setLineCap(.round)

        drawBrightnessRing(state.brightness, center: center, in: context)
        drawVolumeBars(state.volume, muted: state.isMuted, center: center, in: context)

        if let badge = state.badge, badgeWidth > 0 {
            draw(badge: badge.text, in: CGRect(x: side + badgeGap, y: 0, width: badgeWidth, height: side))
        }
    }

    /// 外環：開口朝正下方的 270° gauge，從左下順時針填。
    private static func drawBrightnessRing(_ brightness: Double?, center: CGPoint, in context: CGContext) {
        context.setLineWidth(2.2)
        context.setAlpha(0.25)
        context.addPath(ringPath(center: center, fraction: 1))
        context.strokePath()

        guard let brightness, brightness > 0.001 else { return }
        context.setAlpha(1)
        context.addPath(ringPath(center: center, fraction: brightness))
        context.strokePath()
    }

    private static func ringPath(center: CGPoint, fraction: Double) -> CGPath {
        let start: CGFloat = 225 * .pi / 180
        let path = CGMutablePath()
        path.addArc(
            center: center,
            radius: 6.6,
            startAngle: start,
            endAngle: start - 270 * CGFloat(fraction) * .pi / 180,
            clockwise: true
        )
        return path
    }

    /// 中心三根聲波柱。中間最高，整組隨音量長高；靜音塌成一條橫線
    /// ——和「音量 0」（三根縮到最短的點）刻意畫得不一樣。
    private static func drawVolumeBars(_ volume: Double?, muted: Bool, center: CGPoint, in context: CGContext) {
        context.setLineWidth(barWidth)
        context.setAlpha(volume == nil ? 0.25 : 1)

        if muted {
            context.move(to: CGPoint(x: center.x - 2.7, y: center.y))
            context.addLine(to: CGPoint(x: center.x + 2.7, y: center.y))
            context.strokePath()
            return
        }

        // 柱長從 0 起算（音量 0 時只剩 round cap 的那顆點），不設最小長度——
        // 多數人的音量落在 20–50%，若給了最小長度，這段就全都長得一樣。
        let level = CGFloat(volume ?? 0)
        for (offset, ratio) in zip([-2.6, 0, 2.6] as [CGFloat], [0.62, 1.0, 0.62] as [CGFloat]) {
            let half = 4.4 * level * ratio / 2
            context.move(to: CGPoint(x: center.x + offset, y: center.y - half))
            context.addLine(to: CGPoint(x: center.x + offset, y: center.y + half))
            context.strokePath()
        }
    }

    /// 聲波柱的線寬。比環細一階：環是「量表」、柱是「內容」，
    /// 同粗會糊成一團。
    private static let barWidth: CGFloat = 1.4

    private static func draw(badge: String, in rect: CGRect) {
        let text = NSAttributedString(string: badge, attributes: [
            .font: badgeFont,
            .foregroundColor: NSColor.black,
        ])
        // 以 cap height 的中線對齊圓心（不是 baseline，也不是整個行高的中線）
        // ——數字才會看起來跟圖示同一條中線上。
        let baseline = rect.midY - badgeFont.capHeight / 2
        let size = text.size()
        text.draw(at: CGPoint(x: rect.midX - size.width / 2, y: baseline + badgeFont.descender))
    }

    /// badge 的預留寬度。倒數每秒都在變，寬度若跟著字數縮放，
    /// 選單列上左邊的圖示會跟著抖——所以數字一律以 `00:00` 的寬度置中。
    private static func reservedWidth(forBadge badge: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: badgeFont]
        let actual = (badge as NSString).size(withAttributes: attributes).width
        guard badge.contains(where: \.isNumber) else { return ceil(actual) }
        return ceil(max(actual, ("00:00" as NSString).size(withAttributes: attributes).width))
    }

    private static func accessibilityDescription(_ state: StatusIconState) -> String {
        var parts: [String] = []
        if let brightness = state.brightness {
            parts.append("亮度 \(Int((brightness * 100).rounded()))%")
        }
        if state.isMuted {
            parts.append("已靜音")
        } else if let volume = state.volume {
            parts.append("音量 \(Int((volume * 100).rounded()))%")
        }
        if let badge = state.badge {
            // 唸出來要說對是誰的時間：同一串數字，防睡眠與限時場景的意思差很多
            switch badge.kind {
            case .keepAwake:
                parts.append(badge.text == "∞" ? "螢幕長亮中" : "螢幕長亮剩餘 \(badge.text)")
            case .focus:
                parts.append("專注剩餘 \(badge.text)")
            }
        }
        return parts.isEmpty ? "Chorus" : "Chorus — " + parts.joined(separator: "、")
    }
}
