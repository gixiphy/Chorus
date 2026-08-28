import Testing
@testable import ChorusCore

@Suite("KeepAwakePlanner")
struct KeepAwakeTests {
    @Test("Off never holds an assertion")
    func off() {
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: .off, startedAt: 100, now: 100, connectedDisplayUUIDs: []
        ))
    }

    @Test("Timed mode expires exactly at the duration")
    func timedExpiry() {
        let mode = KeepAwakeMode.duration(seconds: 1800)
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 100, now: 100 + 1799, connectedDisplayUUIDs: []
        ))
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 100, now: 100 + 1800, connectedDisplayUUIDs: []
        ))
    }

    @Test("Indefinite holds until explicitly turned off")
    func indefinite() {
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: .indefinite, startedAt: 0, now: 999_999, connectedDisplayUUIDs: []
        ))
        // 沒有 startedAt ＝ 沒真的啟用
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: .indefinite, startedAt: nil, now: 10, connectedDisplayUUIDs: []
        ))
    }

    @Test("Display-bound mode drops the assertion when that display is unplugged")
    func displayBound() {
        let mode = KeepAwakeMode.whileDisplayConnected(uuid: "AOC")
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50, connectedDisplayUUIDs: ["AOC", "builtin"]
        ))
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50, connectedDisplayUUIDs: ["builtin"]
        ))
    }

    @Test("Remaining seconds counts down and floors at zero")
    func remaining() {
        let mode = KeepAwakeMode.duration(seconds: 60)
        #expect(KeepAwakePlanner.remainingSeconds(mode: mode, startedAt: 10, now: 30) == 40)
        #expect(KeepAwakePlanner.remainingSeconds(mode: mode, startedAt: 10, now: 999) == 0)
        #expect(KeepAwakePlanner.remainingSeconds(mode: .indefinite, startedAt: 10, now: 30) == nil)
    }

    @Test("Command encoding round-trips the remotely controllable modes")
    func encoding() {
        #expect(KeepAwakePlanner.decode(KeepAwakePlanner.encode(.off)) == .off)
        #expect(KeepAwakePlanner.decode(KeepAwakePlanner.encode(.indefinite)) == .indefinite)
        #expect(
            KeepAwakePlanner.decode(KeepAwakePlanner.encode(.duration(seconds: 1800)))
                == .duration(seconds: 1800)
        )
        // 螢幕綁定是本機設定：遙控時退化為無限期
        #expect(
            KeepAwakePlanner.decode(KeepAwakePlanner.encode(.whileDisplayConnected(uuid: "x")))
                == .indefinite
        )
    }
}
