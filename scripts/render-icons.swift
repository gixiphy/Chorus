import AppKit
import ChorusCore

/// Run scripts/render-icons.sh from any directory. Geometry comes from the production
/// renderer; the app asset only adds a background and a fixed, fully lit brand state.
@main
struct RenderIcons {
    @MainActor
    static func main() throws {
        let work = URL(fileURLWithPath: CommandLine.arguments[1])
        let iconset = work.appendingPathComponent("Chorus.iconset")
        try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try png(width: pixels, height: pixels, to: iconset.appendingPathComponent(name)) { context in
                    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
                    appIcon(in: context)
                }
            }
        }
        try png(width: 1024, height: 1024, to: URL(fileURLWithPath: "assets/app-icon.png")) { appIcon(in: $0) }
        try png(width: 204, height: 54, to: URL(fileURLWithPath: "assets/menubar-icon.png")) { context in
            context.scaleBy(x: 3, y: 3)
            mark(state(0.75, 0.65, badge: .init(text: "23:36", kind: .keepAwake)),
                 at: .zero, color: .labelColor, in: context)
        }
        try png(width: 1440, height: 880, to: URL(fileURLWithPath: "assets/icon-design.png")) { context in
            NSColor(calibratedWhite: 0.96, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1440, height: 880))
            text("CHORUS", at: CGPoint(x: 72, y: 790), size: 20, weight: .semibold, color: .secondaryLabelColor)
            text("One mark. Light, sound, focus.", at: CGPoint(x: 72, y: 732), size: 38, weight: .medium)
            context.saveGState()
            context.translateBy(x: 48, y: 170)
            context.scaleBy(x: 0.47, y: 0.47)
            appIcon(in: context)
            context.restoreGState()
            text("APP ICON", at: CGPoint(x: 160, y: 155), size: 14, weight: .semibold, color: .secondaryLabelColor)

            let samples: [(String, StatusIconState)] = [
                ("Normal", state(0.75, 0.65)),
                ("Quiet", state(0.25, 0.20)),
                ("Zero", state(0, 0)),
                ("Muted", state(0.75, 0.65, muted: true)),
                ("No dev", state(nil, nil)),
                ("Awake", state(1, 1, badge: .init(text: "∞", kind: .keepAwake))),
                ("Focus", state(0.75, 0.65, badge: .init(text: "25:00", kind: .focus))),
                ("MacBook", state(0.75, 0.65, output: .laptop)),
                ("Display", state(0.75, 0.65, output: .display)),
                ("AirPods", state(0.75, 0.65, output: .airPods)),
                ("Max mute", state(0.75, 0.65, muted: true, output: .airPodsMax)),
                ("Adj. vol", state(0.30, 0.65, output: .laptop, readout: .init(kind: .volume, value: 0.65))),
                ("Adj. bri", state(0.30, 0.65, output: .laptop, readout: .init(kind: .brightness, value: 0.30)))
            ]
            for (row, dark) in [false, true].enumerated() {
                let y = CGFloat(485 - row * 205)
                let card = CGRect(x: 570, y: y, width: 830, height: 176)
                (dark ? NSColor(calibratedWhite: 0.10, alpha: 1) : .white).setFill()
                NSBezierPath(roundedRect: card, xRadius: 22, yRadius: 22).fill()
                let ink: NSColor = dark ? .white : .black
                for (index, sample) in samples.enumerated() {
                    let x = 600 + CGFloat(index) * 62
                    context.saveGState()
                    context.translateBy(x: x, y: y + 78)
                    context.scaleBy(x: 2.4, y: 2.4)
                    context.clip(to: CGRect(x: 0, y: 0, width: 22, height: 22))
                    mark(sample.1, at: .zero, color: ink, in: context)
                    context.restoreGState()
                    text(sample.0, at: CGPoint(x: x - 4, y: y + 34), size: 13, color: ink.withAlphaComponent(0.65))
                }
            }
            text("ACTUAL SIZE · 22 PT", at: CGPoint(x: 605, y: 225), size: 13, weight: .semibold, color: .secondaryLabelColor)
            for (index, sample) in samples.enumerated() {
                mark(sample.1, at: CGPoint(x: 600 + CGFloat(index) * 62, y: 185), color: .black, in: context)
            }
            text("Volume arc   /   Output device (value while adjusting)   /   Brightness arc",
                 at: CGPoint(x: 605, y: 125), size: 16, color: .secondaryLabelColor)
        }
    }

    static func state(_ brightness: Double?, _ volume: Double?, muted: Bool = false,
                      output: StatusOutputGlyph = .speaker, badge: StatusBadge? = nil,
                      readout: StatusReadout? = nil) -> StatusIconState {
        StatusIconState(brightness: brightness, volume: volume, isMuted: muted, output: output,
                        badge: badge, readout: readout)
    }

    @MainActor
    static func appIcon(in context: CGContext) {
        let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
        let shape = NSBezierPath(roundedRect: tile, xRadius: 184, yRadius: 184)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -12), blur: 24,
                          color: NSColor.black.withAlphaComponent(0.18).cgColor)
        NSColor(calibratedRed: 0.08, green: 0.23, blue: 0.43, alpha: 1).setFill()
        shape.fill()
        context.restoreGState()
        NSGradient(colors: [
            NSColor(calibratedRed: 0.08, green: 0.22, blue: 0.46, alpha: 1),
            NSColor(calibratedRed: 0.08, green: 0.43, blue: 0.64, alpha: 1),
            NSColor(calibratedRed: 0.18, green: 0.66, blue: 0.72, alpha: 1)
        ])!.draw(in: shape, angle: 65)
        context.saveGState()
        shape.addClip()
        NSColor.white.withAlphaComponent(0.20).setStroke()
        shape.lineWidth = 3
        shape.stroke()
        context.restoreGState()

        context.saveGState()
        context.translateBy(x: 192, y: 192)
        context.scaleBy(x: 640 / 22, y: 640 / 22)
        context.clip(to: CGRect(x: 0, y: 0, width: 22, height: 22))
        mark(state(1, 1, badge: .init(text: "∞", kind: .keepAwake)), at: .zero, color: .white, in: context)
        context.restoreGState()
    }

    @MainActor
    static func mark(_ state: StatusIconState, at point: CGPoint, color: NSColor, in context: CGContext) {
        let image = StatusIconRenderer.image(for: state)
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        image.draw(at: point, from: .zero, operation: .sourceOver, fraction: 1)
        color.setFill()
        NSRect(origin: point, size: image.size).fill(using: .sourceIn)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    static func text(_ value: String, at point: CGPoint, size: CGFloat,
                     weight: NSFont.Weight = .regular, color: NSColor = .labelColor) {
        (value as NSString).draw(at: point, withAttributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color
        ])
    }

    @MainActor
    static func png(width: Int, height: Int, to url: URL, draw: (CGContext) -> Void) throws {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let graphics = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        // Keep exported review sheets independent of the machine's current appearance.
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { draw(graphics.cgContext) }
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }
}
