import AppKit
import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("Lid status icon rendering (V-U02-2)")
struct StatusIconRendererTests {
    private func raster(_ state: StatusIconState) throws -> (NSImage, [UInt8]) {
        let image = StatusIconRenderer.image(for: state)
        let width = Int(image.size.width * 2)
        let height = Int(image.size.height * 2)
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = graphics
        graphics.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
        image.draw(in: CGRect(x: 0, y: 0, width: width, height: height),
            from: .zero, operation: .sourceOver, fraction: 1)
        let data = try #require(rep.bitmapData)
        return (image, Array(UnsafeBufferPointer(start: data, count: height * rep.bytesPerRow)))
    }

    @Test func heldChangesMonochromePixelsAndAllOtherStatesMatchBaseline() throws {
        let baseline = StatusIconState(brightness: 0.5, volume: 0.75, isMuted: false,
            badge: StatusBadge(text: "∞", kind: .keepAwake))
        let (baseImage, basePixels) = try raster(baseline)
        let cases: [(String, Bool, Bool?, Bool?, Bool?, Bool)] = [
            ("held", true, true, true, true, true),
            ("pending", true, false, false, true, true),
            ("stale", true, true, true, true, false),
            ("foreign", true, false, true, false, true),
            ("off", false, true, true, true, true),
        ]
        for (name, wants, caller, sleep, owner, ready) in cases {
            var state = baseline
            state.lidSleepDisabled = StatusIcon.lidHoldConfirmed(wantsSleepDisabled: wants,
                callerIsHolder: caller, sleepDisabled: sleep, setByHelper: owner, helperReady: ready)
            let (image, pixels) = try raster(state)
            #expect(image.isTemplate)
            #expect(image.size == baseImage.size)
            if name == "held" {
                #expect(pixels != basePixels)
                #expect(image.accessibilityDescription?.contains(String(localized: "闔蓋也不睡")) == true)
            } else {
                #expect(pixels == basePixels)
                #expect(image.accessibilityDescription == baseImage.accessibilityDescription)
            }
        }
    }

    @Test func badgePreservesCountdownBatteryAndReadoutLayout() throws {
        var base = StatusIconState(brightness: 0.4, volume: 0.8, isMuted: true,
            output: .laptop, badge: StatusBadge(text: "29:59", kind: .keepAwake),
            readout: StatusReadout(kind: .brightness, value: 0.4))
        base.battery = StatusBattery(percent: 50, level: .normal)
        let (baseImage, basePixels) = try raster(base)
        var held = base
        held.lidSleepDisabled = true
        let (heldImage, heldPixels) = try raster(held)
        #expect(baseImage.size == heldImage.size)
        #expect(basePixels != heldPixels)
        let rowWidth = Int(baseImage.size.width * 2) * 4
        // Everything to the right of the 22pt status glyph is byte-identical.
        for y in 0..<Int(baseImage.size.height * 2) {
            let start = y * rowWidth + 44 * 4
            let end = (y + 1) * rowWidth
            #expect(Array(basePixels[start..<end]) == Array(heldPixels[start..<end]))
        }
    }
}
