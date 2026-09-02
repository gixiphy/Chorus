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

@Suite("選單列 badge：多個倒數（B7-1）")
struct StatusIconBadgeTests {
    @Test("兩個倒數同時在跑時顯示較早到期的那個，且說得出那是誰的時間")
    func soonestWins() {
        #expect(StatusIcon.badge(
            keepAwakeRemaining: 3_600, keepAwakeHolding: true, focusRemaining: 1_500
        ) == StatusBadge(text: "25:00", kind: .focus))
        #expect(StatusIcon.badge(
            keepAwakeRemaining: 60, keepAwakeHolding: true, focusRemaining: 1_500
        ) == StatusBadge(text: "1:00", kind: .keepAwake))
    }

    @Test("同時到期算防睡眠的——它是先存在的那個功能")
    func tieGoesToKeepAwake() {
        #expect(StatusIcon.badge(
            keepAwakeRemaining: 600, keepAwakeHolding: true, focusRemaining: 600
        )?.kind == .keepAwake)
    }

    @Test("只有一個倒數時就是它")
    func singleCountdown() {
        #expect(StatusIcon.badge(
            keepAwakeRemaining: nil, keepAwakeHolding: false, focusRemaining: 90
        ) == StatusBadge(text: "1:30", kind: .focus))
        #expect(StatusIcon.badge(
            keepAwakeRemaining: 90, keepAwakeHolding: true, focusRemaining: nil
        ) == StatusBadge(text: "1:30", kind: .keepAwake))
    }

    @Test("∞ 讓位給數字——有具體倒數時不該被沒有數字的符號蓋掉")
    func infinityYieldsToNumber() {
        // 無限期防睡眠（沒有剩餘秒數）＋專注倒數：畫的是專注的數字，
        // 而 kind 必須跟著改，否則無障礙標籤會把它唸成「螢幕長亮剩餘」
        #expect(StatusIcon.badge(
            keepAwakeRemaining: nil, keepAwakeHolding: true, focusRemaining: 300
        ) == StatusBadge(text: "5:00", kind: .focus))
    }

    @Test("沒有任何倒數：持有中回 ∞，否則不畫這一格")
    func infinityAndEmpty() {
        #expect(StatusIcon.badge(
            keepAwakeRemaining: nil, keepAwakeHolding: true, focusRemaining: nil
        ) == StatusBadge(text: "∞", kind: .keepAwake))
        #expect(StatusIcon.badge(
            keepAwakeRemaining: nil, keepAwakeHolding: false, focusRemaining: nil
        ) == nil)
    }

    @Test("既有的 keepAwakeBadge 語意不變（委派給新的三參數版）")
    func legacyBadgeUnchanged() {
        #expect(StatusIcon.keepAwakeBadge(remainingSeconds: 1_500, isHolding: true) == "25:00")
        #expect(StatusIcon.keepAwakeBadge(remainingSeconds: nil, isHolding: true) == "∞")
        #expect(StatusIcon.keepAwakeBadge(remainingSeconds: nil, isHolding: false) == nil)
    }
}
