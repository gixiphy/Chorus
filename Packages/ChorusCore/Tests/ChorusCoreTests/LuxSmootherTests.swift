import Foundation
import Testing
@testable import ChorusCore

@Suite("Lux smoother")
struct LuxSmootherTests {
    @Test("First sample always commits")
    func firstSampleCommits() {
        var smoother = LuxSmoother()
        #expect(smoother.ingest(lux: 300, nowMillis: 0) == 300)
        #expect(smoother.committed == 300)
    }

    @Test("Sub-threshold change is suppressed")
    func subThresholdSuppressed() {
        var smoother = LuxSmoother(relativeThreshold: 0.10, minIntervalMillis: 2000)
        _ = smoother.ingest(lux: 100, nowMillis: 0)
        #expect(smoother.ingest(lux: 105, nowMillis: 3000) == nil)
        #expect(smoother.committed == 100)
    }

    @Test("Change beyond threshold commits")
    func thresholdExceededCommits() {
        var smoother = LuxSmoother(relativeThreshold: 0.10, minIntervalMillis: 2000)
        _ = smoother.ingest(lux: 100, nowMillis: 0)
        #expect(smoother.ingest(lux: 120, nowMillis: 3000) == 120)
        #expect(smoother.committed == 120)
    }

    @Test("Minimum interval is enforced even for large changes")
    func minIntervalEnforced() {
        var smoother = LuxSmoother(relativeThreshold: 0.10, minIntervalMillis: 2000)
        _ = smoother.ingest(lux: 100, nowMillis: 0)
        #expect(smoother.ingest(lux: 500, nowMillis: 1000) == nil)
        // 間隔滿了、變化仍大 → commit
        #expect(smoother.ingest(lux: 500, nowMillis: 2000) == 500)
    }

    @Test("Negative lux clamps to zero")
    func negativeClampsToZero() {
        var smoother = LuxSmoother()
        #expect(smoother.ingest(lux: -20, nowMillis: 0) == 0)
        #expect(smoother.committed == 0)
    }

    @Test("Darkness to light from zero commits")
    func fromZeroCommits() {
        var smoother = LuxSmoother(relativeThreshold: 0.10, minIntervalMillis: 2000)
        _ = smoother.ingest(lux: 0, nowMillis: 0)
        #expect(smoother.ingest(lux: 50, nowMillis: 2500) == 50)
    }
}
