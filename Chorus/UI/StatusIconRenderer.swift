import AppKit
import ChorusCore

/// 選單列圖示的繪製。
///
/// 一張 template image：**只有 alpha 有意義**，顏色由系統決定——
/// 這樣淺色／深色選單列、以及選單被點開時的反白全部自動正確，
/// 不必自己追蹤 appearance。
///
/// 排法沿用 Status Trio：外圈一道從左下掃到右下的主弧是**音量**（比亮度常調，
/// 給它最長的那道）；中央平常是預設輸出裝置，調整當下換成放大的百分比讀數；
/// 底部沿同一個圓畫一小段**亮度**弧。未點亮的軌道一律淡化。
/// 調整當下主弧改畫讀數那個量（數字與圖形對齊），另一個量暫時換到底弧。
/// App icon 也由此 renderer 產生，避免兩套輪廓漸漸分歧。
/// 右側可並排：藍牙耳機電量、防睡眠或限時場景的倒數——兩格各自固定寬度，
/// 不會互相擠掉（選單列的空間是使用者的，電量格可在設定關閉）。
///
/// 中央那格沿用系統聲音選單的圖示語彙：內建喇叭畫那台 Mac、HDMI 畫螢幕、
/// AirPods 畫 AirPods（SF Symbol）；一般喇叭與虛擬裝置維持手繪喇叭。
/// 音量由外圈主弧表達，喇叭本身不再畫聲波。
enum StatusIconRenderer {
    /// 選單列圖示的標準邊長。NSStatusItem 高 22pt，撐滿它。
    static let side: CGFloat = 22
    /// Status Trio 的 120 單位畫布 → pt。
    private static let unit: CGFloat = side / CGFloat(StatusIconGeometry.canvas)
    /// computed 而非 stored：stored 的話是個非 Sendable 的 static，
    /// 但繪製會在非 main actor 的 drawingHandler 裡跑。NSFont 本身不可變，
    /// 每次取用實際上走的是系統的字型快取。
    private static var badgeFont: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .regular) }
    /// 中央讀數：圓體粗字，三位數依環內空間縮放。
    private static var readoutFont: NSFont {
        let size = side * 0.5
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        guard let descriptor = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }
    /// 圖示與右側各段之間的間距。
    private static let segmentGap: CGFloat = 3
    /// 電量段與倒數段之間稍寬一點，兩格並排才分得清。
    private static let batteryBadgeGap: CGFloat = 4
    private static var inactiveAlpha: CGFloat { CGFloat(StatusIcon.inactiveTrackAlpha) }
    private static let detailLineWidth: CGFloat = 1.15

    private static var ringCenter: CGPoint {
        CGPoint(x: CGFloat(StatusIconGeometry.ringCenterX) * unit,
                y: side - CGFloat(StatusIconGeometry.ringCenterY) * unit)
    }
    private static var ringRadius: CGFloat { CGFloat(StatusIconGeometry.ringRadius) * unit }
    private static var ringLineWidth: CGFloat { CGFloat(StatusIconGeometry.ringLineWidth) * unit }

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
        let batteryWidth = state.battery.map { reservedWidth(forBatteryPercent: $0.percent) } ?? 0
        let badgeWidth = state.badge.map { reservedWidth(forBadge: $0.text) } ?? 0
        var totalWidth = side
        if batteryWidth > 0 { totalWidth += segmentGap + batteryWidth }
        if badgeWidth > 0 {
            totalWidth += (batteryWidth > 0 ? batteryBadgeGap : segmentGap) + badgeWidth
        }
        // drawingHandler 會在每個 scale 各呼叫一次，換螢幕（1x↔2x）時自動重畫
        let image = NSImage(size: NSSize(width: totalWidth, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, in: context, batteryWidth: batteryWidth, badgeWidth: badgeWidth)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = accessibilityDescription(state)
        return image
    }

    // MARK: - 繪製

    private static func draw(
        _ state: StatusIconState, in context: CGContext,
        batteryWidth: CGFloat, badgeWidth: CGFloat
    ) {
        context.setStrokeColor(NSColor.black.cgColor)
        context.setFillColor(NSColor.black.cgColor)
        context.setLineCap(.round)

        // 音量比亮度常調，平常放在最長的主弧、亮度在底部那一小段；
        // 調整當下主弧改畫讀數本身，讓中央數字與包著它的弧一致
        let arcs = StatusIconGeometry.arcs(
            brightness: state.brightness, volume: state.volume,
            muted: state.isMuted, readout: state.readout
        )
        drawMainArc(arcs.main, in: context)
        if let readout = state.readout {
            drawReadout(readout, in: context)
        } else if let symbol = state.output.symbolName {
            drawDeviceSymbol(symbol, volume: state.volume, muted: state.isMuted, in: context)
        } else {
            drawSpeaker(state.volume, muted: state.isMuted, in: context)
        }
        drawBottomArc(arcs.bottom, in: context)

        var x = side
        if let battery = state.battery, batteryWidth > 0 {
            x += segmentGap
            context.setAlpha(1)
            draw(battery: battery, in: CGRect(x: x, y: 0, width: batteryWidth, height: side), context: context)
            x += batteryWidth
        }
        if let badge = state.badge, badgeWidth > 0 {
            x += state.battery != nil ? batteryBadgeGap : segmentGap
            context.setAlpha(1)
            draw(badge: badge.text, in: CGRect(x: x, y: 0, width: badgeWidth, height: side))
        }
    }

    // MARK: 主弧（平常是音量；調整當下是讀數）

    /// 軌道整段淡化，照比例點亮；`progress == nil`（靜音、沒裝置）只剩軌道。
    private static func drawMainArc(_ progress: Double?, in context: CGContext) {
        context.setLineWidth(ringLineWidth)
        context.setAlpha(inactiveAlpha)
        strokeMain(segments: StatusIconGeometry.arcSegments(progress: 1, gapFraction: 0), in: context)

        if let progress {
            context.setAlpha(1)
            strokeMain(segments: StatusIconGeometry.arcSegments(progress: progress, gapFraction: 0), in: context)
        }
    }

    private static func drawReadout(_ readout: StatusReadout, in context: CGContext) {
        let font = readoutFont
        let text = NSAttributedString(string: String(readout.percent), attributes: [
            .font: font, .foregroundColor: NSColor.black, .kern: -font.pointSize * 0.04,
        ])
        let size = text.size()
        // 以數字外框的對角線限制縮放，讓 100 的四角也留在環內並保有留白。
        let diameter = 2 * (ringRadius - ringLineWidth / 2 - 0.7)
        let scale = min(1, diameter / hypot(size.width, font.capHeight))
        context.saveGState()
        context.setAlpha(1)
        context.translateBy(x: ringCenter.x, y: ringCenter.y)
        context.scaleBy(x: scale, y: scale)
        text.draw(at: CGPoint(x: -size.width / 2, y: -font.capHeight / 2 + font.descender))
        context.restoreGState()
    }

    private static func strokeMain(segments: [StatusIconGeometry.ArcSegment], in context: CGContext) {
        for segment in segments {
            context.addArc(
                center: ringCenter, radius: ringRadius,
                startAngle: mainArcAngle(progress: segment.from),
                endAngle: mainArcAngle(progress: segment.to),
                clockwise: true
            )
            context.strokePath()
        }
    }

    /// Status Trio 的角度是 SVG 慣例（y 往下、順時針為正）；CoreGraphics 的 y 往上，取負即可。
    private static func mainArcAngle(progress: Double) -> CGFloat {
        -CGFloat(StatusIconGeometry.mainArcStart + StatusIconGeometry.mainArcSweep * progress)
    }

    // MARK: 底弧（平常是亮度；調亮度時暫時換成音量）

    private static func drawBottomArc(_ progress: Double?, in context: CGContext) {
        context.setLineWidth(ringLineWidth)
        context.setAlpha(inactiveAlpha)
        strokeBottom(progress: 1, in: context)

        guard let progress else { return }
        context.setAlpha(1)
        strokeBottom(progress: progress, in: context)
    }

    private static func strokeBottom(progress: Double, in context: CGContext) {
        let start = StatusIconGeometry.bottomArcStart
        let end = start - (start - StatusIconGeometry.bottomArcEnd) * progress
        context.addArc(
            center: ringCenter, radius: ringRadius,
            startAngle: -CGFloat(start), endAngle: -CGFloat(end),
            clockwise: false
        )
        context.strokePath()
    }

    // MARK: 中央裝置

    /// 環內能放符號的範圍：四角離圓心約 7.1pt，留在環的內緣（約 8.7pt）裡面。
    private static var symbolBox: CGRect {
        CGRect(x: ringCenter.x - 5.75, y: ringCenter.y - 4.1, width: 11.5, height: 8.2)
    }

    /// 固定的喇叭輪廓；靜音另畫叉號，未知輸出則淡化。
    /// 輪廓沿用舊的 18pt 座標（喇叭身 x 5–8.7、y 7–12.2），平移到環心。
    private static func drawSpeaker(_ volume: Double?, muted: Bool, in context: CGContext) {
        context.saveGState()
        context.setAlpha(volume == nil && !muted ? inactiveAlpha : 1)
        // 靜音時喇叭身＋叉號一起置中，否則只置中喇叭身；整組隨畫布放大
        let groupCenterX: CGFloat = muted ? 8.9 : 6.85
        let scale = side / 18
        context.translateBy(x: ringCenter.x, y: ringCenter.y)
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -groupCenterX, y: -9.6)
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

        if muted {
            context.setLineWidth(detailLineWidth)
            for (start, end) in [(CGPoint(x: 10.4, y: 8.4), CGPoint(x: 12.8, y: 10.8)),
                                 (CGPoint(x: 10.4, y: 10.8), CGPoint(x: 12.8, y: 8.4))] {
                context.move(to: start)
                context.addLine(to: end)
                context.strokePath()
            }
        }
        context.restoreGState()
    }

    /// 系統風格的裝置符號，等比縮到 `symbolBox` 內置中。音量畫不進
    /// 一台筆電的輪廓裡，所以這條只管「哪個裝置」與靜音；
    /// 靜音照系統的 slash 變體：先挖一道透明溝，再畫斜線。
    private static func drawDeviceSymbol(_ name: String, volume: Double?, muted: Bool, in context: CGContext) {
        guard let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            // 只要輪廓：階層式著色會把筆電螢幕那塊畫成半透明，在 template 上變成灰底
            .withSymbolConfiguration(.init(pointSize: 9, weight: .medium).applying(.preferringMonochrome())),
            symbol.size.width > 0, symbol.size.height > 0
        else { return }
        let box = symbolBox
        let scale = min(box.width / symbol.size.width, box.height / symbol.size.height)
        let size = CGSize(width: symbol.size.width * scale, height: symbol.size.height * scale)
        let rect = CGRect(
            x: box.midX - size.width / 2, y: box.midY - size.height / 2,
            width: size.width, height: size.height
        )
        context.setAlpha(1)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver,
                    fraction: volume == nil && !muted ? inactiveAlpha : 1)

        guard muted else { return }
        // 斜線與挖出的透明溝都得留在環的內緣裡，不然會把環也切斷
        let start = CGPoint(x: box.minX + 1.6, y: box.maxY - 0.2)
        let end = CGPoint(x: box.maxX - 1.6, y: box.minY + 0.2)
        context.saveGState()
        context.setBlendMode(.clear)
        context.setLineWidth(2.0)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        context.restoreGState()
        context.setLineWidth(detailLineWidth)
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    // MARK: 右側電量／倒數

    private static func draw(battery: StatusBattery, in rect: CGRect, context: CGContext) {
        let text = "\(battery.percent)%"
        let attributed = NSAttributedString(string: text, attributes: [
            .font: badgeFont,
            .foregroundColor: NSColor.black,
        ])
        let textSize = attributed.size()
        let iconW: CGFloat = 6
        let iconH: CGFloat = 11
        let gap: CGFloat = 2
        let contentW = iconW + gap + textSize.width
        let originX = rect.midX - contentW / 2
        let iconRect = CGRect(
            x: originX,
            y: rect.midY - iconH / 2,
            width: iconW,
            height: iconH
        )
        drawBatteryGlyph(fill: CGFloat(battery.percent) / 100, in: iconRect, context: context)
        let baseline = rect.midY - badgeFont.capHeight / 2
        attributed.draw(at: CGPoint(
            x: iconRect.maxX + gap,
            y: baseline + badgeFont.descender
        ))
    }

    /// 手繪直立小電池：外框＋頂端凸點，內部由下往上依百分比填滿。template 只有 alpha，
    /// 低電量靠填滿程度表達，不靠顏色。（CGContext 原點在左下，y 往上長。）
    private static func drawBatteryGlyph(fill: CGFloat, in rect: CGRect, context: CGContext) {
        let nubW: CGFloat = 2.6
        let nubH: CGFloat = 1.2
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - nubH)
        let nub = CGRect(
            x: rect.midX - nubW / 2,
            y: body.maxY,
            width: nubW,
            height: nubH
        )
        context.setLineWidth(1)
        context.stroke(body.insetBy(dx: 0.5, dy: 0.5))
        context.fill(nub)

        let inset: CGFloat = 1.5
        let inner = body.insetBy(dx: inset, dy: inset)
        guard inner.width > 0, inner.height > 0 else { return }
        let filled = CGRect(
            x: inner.minX,
            y: inner.minY,
            width: inner.width,
            height: inner.height * min(max(fill, 0), 1)
        )
        if filled.height > 0 {
            context.fill(filled)
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

    /// 電量段預留寬度：小電池圖 + 間距 + `100%`，數字從 100 掉到 9 時左邊圖示不抖。
    private static func reservedWidth(forBatteryPercent _: Int) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: badgeFont]
        let textW = ("100%" as NSString).size(withAttributes: attributes).width
        return ceil(6 + 2 + textW)
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
        if let battery = state.battery {
            if let left = battery.left, let right = battery.right, left != right {
                parts.append(String(localized: "左耳 \(left)%、右耳 \(right)%"))
            } else {
                parts.append(String(localized: "耳機電量 \(battery.percent)%"))
            }
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
