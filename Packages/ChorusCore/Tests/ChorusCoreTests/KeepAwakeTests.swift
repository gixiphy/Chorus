import Testing
@testable import ChorusCore

@Suite("KeepAwakePlanner")
struct KeepAwakeTests {
    @Test("Off never holds an assertion")
    func off() {
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: .off, startedAt: 100, now: 100, connectedDisplayUUIDs: [], runningAppBundleIDs: []
        ))
    }

    @Test("Timed mode expires exactly at the duration")
    func timedExpiry() {
        let mode = KeepAwakeMode.duration(seconds: 1800)
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 100, now: 100 + 1799, connectedDisplayUUIDs: [], runningAppBundleIDs: []
        ))
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 100, now: 100 + 1800, connectedDisplayUUIDs: [], runningAppBundleIDs: []
        ))
    }

    @Test("Indefinite holds until explicitly turned off")
    func indefinite() {
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: .indefinite, startedAt: 0, now: 999_999, connectedDisplayUUIDs: [], runningAppBundleIDs: []
        ))
        // 沒有 startedAt ＝ 沒真的啟用
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: .indefinite, startedAt: nil, now: 10, connectedDisplayUUIDs: [], runningAppBundleIDs: []
        ))
    }

    @Test("Display-bound mode drops the assertion when that display is unplugged")
    func displayBound() {
        let mode = KeepAwakeMode.whileDisplayConnected(uuid: "AOC")
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50, connectedDisplayUUIDs: ["AOC", "builtin"], runningAppBundleIDs: []
        ))
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50, connectedDisplayUUIDs: ["builtin"], runningAppBundleIDs: []
        ))
    }

    @Test("App-bound mode follows the app in and out of the running set")
    func appBound() {
        let mode = KeepAwakeMode.whileAppRunning(bundleID: "com.apple.FinalCut")
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: ["com.apple.FinalCut", "com.apple.finder"]
        ))
        // App 關掉就失效，但模式留著——再開時要能自己恢復
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: ["com.apple.finder"]
        ))
        // 沒有 startedAt ＝ 沒真的啟用
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: nil, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: ["com.apple.FinalCut"]
        ))
    }

    @Test("Remaining seconds counts down and floors at zero")
    func remaining() {
        let mode = KeepAwakeMode.duration(seconds: 60)
        #expect(KeepAwakePlanner.remainingSeconds(mode: mode, startedAt: 10, now: 30) == 40)
        #expect(KeepAwakePlanner.remainingSeconds(
            mode: .whileAppRunning(bundleID: "x"), startedAt: 10, now: 30
        ) == nil)
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
        // 螢幕／App 綁定是本機設定：遙控時退化為無限期
        #expect(
            KeepAwakePlanner.decode(KeepAwakePlanner.encode(.whileDisplayConnected(uuid: "x")))
                == .indefinite
        )
        #expect(
            KeepAwakePlanner.decode(KeepAwakePlanner.encode(.whileAppRunning(bundleID: "x")))
                == .indefinite
        )
    }
}
