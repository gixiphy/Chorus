import AppKit
import ChorusCore

/// 選單列圖示的繪製。
///
/// 一張 template image：**只有 alpha 有意義**，顏色由系統決定——
/// 這樣淺色／深色選單列、以及選單被點開時的反白全部自動正確，
/// 不必自己追蹤 appearance。
///
/// 共用標誌：亮度開口環、中央輸出裝置、底部活動標記。App icon 也由此 renderer
/// 產生，避免兩套輪廓漸漸分歧。右側保留防睡眠或限時場景的倒數。
///
/// 中央那格沿用系統聲音選單的圖示語彙：內建喇叭畫那台 Mac、HDMI 畫螢幕、
/// AirPods 畫 AirPods（SF Symbol）；一般喇叭與虛擬裝置維持手繪喇叭，
/// 聲波隨音量亮起——app icon 用的就是這個狀態，符號換了它也不動。
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
        if let symbol = state.output.symbolName {
            drawDeviceSymbol(symbol, volume: state.volume, muted: state.isMuted, in: context)
        } else {
            drawSpeaker(state.volume, muted: state.isMuted, in: context)
        }
        drawActivity(state.badge?.kind, in: context)

        if let badge = state.badge, badgeWidth > 0 {
            context.setAlpha(1)
            draw(badge: badge.text, in: CGRect(x: side + badgeGap, y: 0, width: badgeWidth, height: side))
        }
    }

    /// 外環：280°，下方開口留給活動標記；和內部喇叭保持至少一個線寬的留白。
    private static func drawBrightnessRing(_ brightness: Double?, center: CGPoint, in context: CGContext) {
        context.setLineWidth(1.7)
        context.setAlpha(0.28)
        context.addPath(ringPath(center: center, fraction: 1))
        context.strokePath()

        guard let brightness, brightness > 0.001 else { return }
        context.setAlpha(1)
        context.addPath(ringPath(center: center, fraction: brightness))
        context.strokePath()
    }

    private static func ringPath(center: CGPoint, fraction: Double) -> CGPath {
        let start: CGFloat = 230 * .pi / 180
        let path = CGMutablePath()
        path.addArc(
            center: center,
            radius: 7.2,
            startAngle: start,
            endAngle: start - 280 * CGFloat(fraction) * .pi / 180,
            clockwise: true
        )
        return path
    }

    /// 固定的喇叭輪廓讓低音量也能辨識；兩道聲波依音量逐段亮起。
    /// 零音量保留喇叭，靜音另畫叉號，未知輸出則整組淡化。
    private static func drawSpeaker(_ volume: Double?, muted: Bool, in context: CGContext) {
        context.setFillColor(NSColor.black.cgColor)
        context.setAlpha(volume == nil && !muted ? 0.28 : 1)
        let speaker = CGMutablePath()
        speaker.move(to: CGPoint(x: 5.0, y: 8.6))
        speaker.addLine(to: CGPoint(x: 6.3, y: 8.6))
        speaker.addLine(to: CGPoint(x: 8.3, y: 7.0))
        speaker.addQuadCurve(to: CGPoint(x: 8.7, y: 7.2), control: CGPoint(x: 8.7, y: 6.7))
        speaker.addLine(to: CGPoint(x: 8.7, y: 12.0))
        speaker.addQuadCurve(to: CGPoint(x: 8.3, y: 12.2), control: CGPoint(x: 8.7, y: 12.5))
        speaker.addLine(to: CGPoint(x: 6.3, y: 10.6))
        speaker.addLine(to: CGPoint(x: 5.0, y: 10.6))
        speaker.closeSubpath()
        context.addPath(speaker)
        context.fillPath()

        context.setLineWidth(1.15)
        if muted {
            for (start, end) in [(CGPoint(x: 10.4, y: 8.4), CGPoint(x: 12.8, y: 10.8)),
                                 (CGPoint(x: 10.4, y: 10.8), CGPoint(x: 12.8, y: 8.4))] {
                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()
            }
        } else {
            let level = volume ?? 0
            for (index, radius) in [2.5, 4.6].enumerated() {
                context.setAlpha(0.18 + 0.82 * min(max(level * 2 - Double(index), 0), 1))
                context.addArc(center: CGPoint(x: 8.0, y: 9.6), radius: radius,
                               startAngle: -.pi / 4, endAngle: .pi / 4, clockwise: false)
                context.strokePath()
            }
        }
    }

    /// 環內、活動標記上方能放符號的範圍：四角離圓心約 6.1pt，
    /// 剛好留在 7.2pt 半徑、1.7pt 線寬的環的內緣裡面。
    private static let symbolBox = CGRect(x: 4.0, y: 6.1, width: 10.0, height: 7.0)

    /// 系統風格的裝置符號，等比縮到 `symbolBox` 內置中。音量畫不進
    /// 一台筆電的輪廓裡，所以這條只管「哪個裝置」與靜音；
    /// 靜音照系統的 slash 變體：先挖一道透明溝，再畫斜線。
    private static func drawDeviceSymbol(_ name: String, volume: Double?, muted: Bool, in context: CGContext) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            // 只要輪廓：階層式著色會把筆電螢幕那塊畫成半透明，在 template 上變成灰底
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium).applying(.preferringMonochrome())),
            symbol.size.width > 0, symbol.size.height > 0
        else { return }
        let scale = min(symbolBox.width / symbol.size.width, symbolBox.height / symbol.size.height)
        let size = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let rect = CGRect(
            x: symbolBox.midX - size.width / 2, y: symbolBox.midY - size.height / 2,
            width: size.width, height: size.height
        )
        context.setAlpha(1)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver,
                    fraction: volume == nil && !muted ? 0.28 : 1)

        guard muted else { return }
        // 斜線與挖出的透明溝都得留在環的內緣裡，不然會把環也切斷
        let start = CGPoint(x: symbolBox.minX + 1.6, y: symbolBox.maxY - 0.2)
        let end = CGPoint(x: symbolBox.maxX - 1.6, y: symbolBox.minY + 0.2)
        context.saveGState()
        context.setBlendMode(.clear)
        context.setLineWidth(2.0)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
        context.setLineWidth(1.15)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    /// 底部的短橫是長亮；雙點是專注。未啟用時保留淡色短橫，輪廓維持一致。
    private static func drawActivity(_ kind: StatusBadgeKind?, in context: CGContext) {
        context.setAlpha(kind == nil ? 0.28 : 1)
        context.setLineWidth(1.7)
        if kind == .focus {
            context.setFillColor(NSColor.black.cgColor)
            for x in [6.8, 9.5] {
                context.fillEllipse(in: CGRect(x: x, y: 1.05, width: 1.7, height: 1.7))
            }
        } else {
            context.move(to: CGPoint(x: 7.4, y: 1.9))
            context.addLine(to: CGPoint(x: 10.6, y: 1.9))
            context.strokePath()
        }
    }

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
            parts.append(String(localized: "亮度 \(Int((brightness * 100).rounded()))%"))
        }
        if state.isMuted {
            parts.append(String(localized: "已靜音"))
        } else if let volume = state.volume {
            parts.append(String(localized: "音量 \(Int((volume * 100).rounded()))%"))
        }
        if let badge = state.badge {
            // 唸出來要說對是誰的時間：同一串數字，防睡眠與限時場景的意思差很多
            switch badge.kind {
            case .keepAwake:
                parts.append(badge.text == "∞" ? String(localized: "螢幕長亮中") : String(localized: "螢幕長亮剩餘 \(badge.text)"))
            case .focus:
                parts.append(String(localized: "專注剩餘 \(badge.text)"))
            }
        }
        return parts.isEmpty ? "Chorus" : "Chorus — " + parts.joined(separator: String(localized: "、"))
    }
}
