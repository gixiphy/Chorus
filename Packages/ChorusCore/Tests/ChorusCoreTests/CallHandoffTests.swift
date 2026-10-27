import Foundation
import Testing
@testable import ChorusCore

@Suite("NominalSampleRate")
struct NominalSampleRateTests {
    @Test("非有限值或 ≤ 0 → nil")
    func rejectsNonPositiveAndNonFinite() {
        #expect(NominalSampleRate(hertz: 0) == nil)
        #expect(NominalSampleRate(hertz: -1) == nil)
        #expect(NominalSampleRate(hertz: .nan) == nil)
        #expect(NominalSampleRate(hertz: .infinity) == nil)
        #expect(NominalSampleRate(hertz: -.infinity) == nil)
    }

    @Test("語音頻段恰好 8000／16000／24000")
    func telephonyBandExactRates() {
        for hz in [8000.0, 16000.0, 24000.0] {
            let rate = NominalSampleRate(hertz: hz)
            #expect(rate?.isTelephonyBand == true)
        }
        for hz in [11025.0, 22050.0, 32000.0, 44100.0, 48000.0, 96000.0] {
            let rate = NominalSampleRate(hertz: hz)
            #expect(rate?.isTelephonyBand == false)
        }
    }
}

@Suite("TelephonyRateMemory")
struct TelephonyRateMemoryTests {
    private typealias Memory = TelephonyRateMemory<ManualClock.Instant>

    private func instant(_ seconds: Double) -> ManualClock.Instant {
        ManualClock.Instant(offset: .seconds(seconds))
    }

    private func rate(_ hz: Double) -> NominalSampleRate {
        NominalSampleRate(hertz: hz)!
    }

    @Test("記 24000 後回到 48000 不清除；+14s 再 +14s 仍 recent")
    func remembersAcrossNonTelephony() {
        var memory = Memory()
        let t0 = instant(0)
        memory.record(rate(24000), outputUID: "A", at: t0)
        memory.record(rate(48000), outputUID: "A", at: instant(14))
        #expect(memory.isRecentTelephony(outputUID: "A", at: instant(28)))
    }

    @Test("剛好 60.000 s 仍算 recent")
    func inclusiveAtSixtySeconds() {
        var memory = Memory()
        memory.record(rate(24000), outputUID: "A", at: instant(0))
        #expect(memory.isRecentTelephony(outputUID: "A", at: instant(60)))
    }

    @Test("60.001 s 過期")
    func expiresJustAfterSixty() {
        var memory = Memory()
        memory.record(rate(24000), outputUID: "A", at: instant(0))
        #expect(!memory.isRecentTelephony(outputUID: "A", at: ManualClock.Instant(offset: .seconds(60) + .milliseconds(1))))
    }

    @Test("後續語音頻段延長窗口")
    func laterTelephonyExtendsWindow() {
        var memory = Memory()
        memory.record(rate(24000), outputUID: "A", at: instant(0))
        memory.record(rate(16000), outputUID: "A", at: instant(50))
        #expect(memory.isRecentTelephony(outputUID: "A", at: instant(100)))
    }

    @Test("expiry 是最後一次語音頻段 + 60 s；只記 48000 → nil")
    func expiryMatchesLastTelephony() {
        var memory = Memory()
        #expect(memory.expiry(outputUID: "A") == nil)
        memory.record(rate(48000), outputUID: "A", at: instant(0))
        #expect(memory.expiry(outputUID: "A") == nil)
        memory.record(rate(24000), outputUID: "A", at: instant(10))
        memory.record(rate(48000), outputUID: "A", at: instant(20))
        #expect(memory.expiry(outputUID: "A") == instant(70))
    }

    @Test("UID 互不干擾")
    func perUIDIsolation() {
        var memory = Memory()
        memory.record(rate(24000), outputUID: "A", at: instant(0))
        #expect(!memory.isRecentTelephony(outputUID: "B", at: instant(1)))
    }
}

@Suite("CallHandoffPolicy")
struct CallHandoffPolicyTests {
    private let home = "home-uid"
    private let other = "other-uid"
    private let screen = "screen-uid"

    private func decide(
        held: String? = nil,
        homeUID: String? = "home-uid",
        followsDefault: Bool = true,
        defaultUID: String? = "home-uid",
        available: Set<String> = ["home-uid", "other-uid", "screen-uid"],
        homeTelephonyRecent: Bool = false,
        deferralExpired: Bool = true
    ) -> CallHandoffDecision {
        CallHandoffPolicy.decide(
            heldUID: held,
            homeUID: homeUID,
            followsDefault: followsDefault,
            defaultUID: defaultUID,
            available: available,
            homeTelephonyRecent: homeTelephonyRecent,
            deferralExpired: deferralExpired
        )
    }

    @Test("hold 中且原 UID 回來 → resume")
    func resumeWhenHeldDeviceReturns() {
        #expect(decide(held: home, available: [home, screen]) == .resume(outputUID: home))
    }

    @Test("hold 中、原 UID 不在、預設是另一副耳機 → stayHeld")
    func stayHeldWhenMissing() {
        #expect(decide(held: home, defaultUID: other, available: [other, screen]) == .stayHeld(outputUID: home))
    }

    @Test("hold 中且語音紀錄已過期 → 仍 stayHeld")
    func stayHeldIgnoresExpiredTelephony() {
        #expect(decide(held: home, available: [screen], homeTelephonyRecent: false) == .stayHeld(outputUID: home))
    }

    @Test("沒有 hold、home 不在、有語音紀錄 → enterHold")
    func enterHoldOnTelephonyDisappearance() {
        #expect(decide(
            homeUID: home,
            available: [screen],
            homeTelephonyRecent: true
        ) == .enterHold(outputUID: home))
    }

    @Test("home 不在、沒有語音紀錄 → normal")
    func normalWithoutTelephony() {
        #expect(decide(available: [screen], homeTelephonyRecent: false) == .normal)
    }

    @Test("跟隨預設、預設已換、有語音紀錄、延後未到期 → deferFollow")
    func deferFollowWhileSettling() {
        #expect(decide(
            followsDefault: true,
            defaultUID: screen,
            available: [home, screen],
            homeTelephonyRecent: true,
            deferralExpired: false
        ) == .deferFollow(outputUID: home))
    }

    @Test("延後期限已到 → normal")
    func normalAfterDeferralExpires() {
        #expect(decide(
            followsDefault: true,
            defaultUID: screen,
            available: [home, screen],
            homeTelephonyRecent: true,
            deferralExpired: true
        ) == .normal)
    }

    @Test("指定路由不延後跟隨 → normal")
    func routedAppDoesNotDefer() {
        #expect(decide(
            followsDefault: false,
            defaultUID: screen,
            available: [home, screen],
            homeTelephonyRecent: true,
            deferralExpired: false
        ) == .normal)
    }

    @Test("home 還在、預設沒換 → normal")
    func normalWhenDefaultUnchanged() {
        #expect(decide(
            followsDefault: true,
            defaultUID: home,
            available: [home, screen],
            homeTelephonyRecent: true,
            deferralExpired: false
        ) == .normal)
    }

    @Test("home 為 nil → normal")
    func normalWithoutHome() {
        #expect(decide(homeUID: nil, available: [screen], homeTelephonyRecent: true) == .normal)
    }
}

@Suite("HandoffPlaybackPolicy")
struct HandoffPlaybackPolicyTests {
    @Test("pauseGate")
    func pauseGate() {
        #expect(HandoffPlaybackPolicy.pauseGate(canAddress: false, targetAudible: true) == .notAddressable)
        #expect(HandoffPlaybackPolicy.pauseGate(canAddress: false, targetAudible: false) == .notAddressable)
        #expect(HandoffPlaybackPolicy.pauseGate(canAddress: true, targetAudible: false) == .userAlreadyPaused)
        #expect(HandoffPlaybackPolicy.pauseGate(canAddress: true, targetAudible: true) == nil)
    }

    @Test("afterPauseSent")
    func afterPauseSent() {
        #expect(HandoffPlaybackPolicy.afterPauseSent(.delivered) == .requested)
        #expect(HandoffPlaybackPolicy.afterPauseSent(.unsupported) == .notAddressable)
        #expect(HandoffPlaybackPolicy.afterPauseSent(.failed("x")) == .failed)
    }

    @Test("verify")
    func verify() {
        #expect(HandoffPlaybackPolicy.verify(.requested, targetAudible: true) == .failed)
        #expect(HandoffPlaybackPolicy.verify(.requested, targetAudible: false) == .confirmed)
        #expect(HandoffPlaybackPolicy.verify(.pending, targetAudible: false) == .pending)
        #expect(HandoffPlaybackPolicy.verify(.confirmed, targetAudible: true) == .confirmed)
    }

    @Test("shouldAutoPlay 只有 confirmed＋可定址＋不發聲")
    func shouldAutoPlay() {
        #expect(HandoffPlaybackPolicy.shouldAutoPlay(.confirmed, canAddressNow: true, targetAudible: false))
        #expect(!HandoffPlaybackPolicy.shouldAutoPlay(.confirmed, canAddressNow: false, targetAudible: false))
        #expect(!HandoffPlaybackPolicy.shouldAutoPlay(.confirmed, canAddressNow: true, targetAudible: true))
        for state: HandoffPauseState in [
            .pending, .notAddressable, .userAlreadyPaused, .requested, .failed
        ] {
            #expect(!HandoffPlaybackPolicy.shouldAutoPlay(state, canAddressNow: true, targetAudible: false))
        }
    }
}
