import Testing
@testable import ChorusCore

@Suite("StatusIcon")
struct StatusIconTests {
    @Test("Quantizing collapses sub-step changes so the icon stops redrawing")
    func quantizeCollapses() {
        #expect(StatusIcon.quantize(0.500) == StatusIcon.quantize(0.505))
        #expect(StatusIcon.quantize(0.50) != StatusIcon.quantize(0.55))
        #expect(StatusIcon.quantize(nil) == nil)
    }

    @Test("Quantizing clamps out-of-range values")
    func quantizeClamps() {
        #expect(StatusIcon.quantize(-0.3) == 0)
        #expect(StatusIcon.quantize(1.8) == 1)
    }

    @Test("Countdown reads M:SS below 100 minutes")
    func countdownMinutesSeconds() {
        #expect(StatusIcon.countdownText(remainingSeconds: 1800) == "30:00")
        #expect(StatusIcon.countdownText(remainingSeconds: 59) == "0:59")
        #expect(StatusIcon.countdownText(remainingSeconds: 0) == "0:00")
        #expect(StatusIcon.countdownText(remainingSeconds: 5999) == "99:59")
    }

    @Test("Long durations switch to hours so the badge stays narrow")
    func countdownHours() {
        #expect(StatusIcon.countdownText(remainingSeconds: 6000) == "1h40")
        #expect(StatusIcon.countdownText(remainingSeconds: 9000) == "2h30")
    }

    @Test("Negative remaining reads as zero rather than a minus sign")
    func countdownNeverNegative() {
        #expect(StatusIcon.countdownText(remainingSeconds: -5) == "0:00")
    }

    @Test("Non-timed keep-awake modes badge as infinity, off badges as nothing")
    func badge() {
        #expect(StatusIcon.keepAwakeBadge(remainingSeconds: 90, isHolding: true) == "1:30")
        #expect(StatusIcon.keepAwakeBadge(remainingSeconds: nil, isHolding: true) == "∞")
        #expect(StatusIcon.keepAwakeBadge(remainingSeconds: nil, isHolding: false) == nil)
    }
}
