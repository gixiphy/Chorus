import Foundation
import Testing
@testable import ChorusCore

@Suite("Ambient curve")
struct AmbientCurveTests {
    @Test("0 lx maps to minBrightness, maxLux maps to full brightness")
    func endpoints() {
        let curve = AmbientCurve(minBrightness: 0.15, maxLux: 1200)
        #expect(curve.map(lux: 0) == 0.15)
        #expect(abs(curve.map(lux: 1200) - 1.0) < 1e-9)
    }

    @Test("Curve is monotonically increasing")
    func monotonic() {
        let curve = AmbientCurve()
        var previous = -Double.infinity
        for lux in stride(from: 0.0, through: 1500.0, by: 25.0) {
            let value = curve.map(lux: lux)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test("Out-of-range lux clamps to endpoints")
    func clamping() {
        let curve = AmbientCurve(minBrightness: 0.2, maxLux: 800)
        #expect(curve.map(lux: -50) == 0.2)
        #expect(abs(curve.map(lux: 99999) - 1.0) < 1e-9)
    }

    @Test("Offsets are summed then clamped to 0…1")
    func offsets() {
        #expect(abs(AmbientCurve.applyOffsets(base: 0.5, displayOffset: 0.2, deviceOffset: 0.1) - 0.8) < 1e-9)
        #expect(AmbientCurve.applyOffsets(base: 0.9, displayOffset: 0.3, deviceOffset: 0.0) == 1.0)
        #expect(AmbientCurve.applyOffsets(base: 0.1, displayOffset: -0.3, deviceOffset: -0.1) == 0.0)
    }

    @Test("Init sanitizes parameters")
    func sanitizedInit() {
        let curve = AmbientCurve(minBrightness: 1.7, maxLux: -3)
        #expect(curve.minBrightness == 1.0)
        #expect(curve.maxLux == 1.0)
    }

    @Test("Codable round-trip preserves parameters")
    func codableRoundTrip() throws {
        let curve = AmbientCurve(minBrightness: 0.25, maxLux: 900)
        let data = try JSONEncoder().encode(curve)
        let decoded = try JSONDecoder().decode(AmbientCurve.self, from: data)
        #expect(decoded == curve)
    }
}
