import Foundation
import Testing
@testable import ChorusCore

@Suite("KeepAwakePlanner")
struct KeepAwakeTests {
    @Test("Off never holds an assertion")
    func off() {
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: .off, startedAt: 100, now: 100,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: false
        ,
            systemBusy: false
        ))
    }

    @Test("Timed mode expires exactly at the duration")
    func timedExpiry() {
        let mode = KeepAwakeMode.duration(seconds: 1800)
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 100, now: 100 + 1799,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: false
        ,
            systemBusy: false
        ))
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 100, now: 100 + 1800,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: false
        ,
            systemBusy: false
        ))
    }

    @Test("Indefinite holds until explicitly turned off")
    func indefinite() {
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: .indefinite, startedAt: 0, now: 999_999,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: false
        ,
            systemBusy: false
        ))
        // 沒有 startedAt ＝ 沒真的啟用
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: .indefinite, startedAt: nil, now: 10,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: false
        ,
            systemBusy: false
        ))
    }

    @Test("Display-bound mode drops the assertion when that display is unplugged")
    func displayBound() {
        let mode = KeepAwakeMode.whileDisplayConnected(uuid: "AOC")
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: ["AOC", "builtin"], runningAppBundleIDs: [], agentsWorking: false
        ,
            systemBusy: false
        ))
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: ["builtin"], runningAppBundleIDs: [], agentsWorking: false
        ,
            systemBusy: false
        ))
    }

    @Test("App-bound mode follows the app in and out of the running set")
    func appBound() {
        let mode = KeepAwakeMode.whileAppRunning(bundleID: "com.apple.FinalCut")
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: [],
            runningAppBundleIDs: ["com.apple.FinalCut", "com.apple.finder"], agentsWorking: false
        ,
            systemBusy: false
        ))
        // App 關掉就失效，但模式留著——再開時要能自己恢復
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: ["com.apple.finder"], agentsWorking: false
        ,
            systemBusy: false
        ))
        // 沒有 startedAt ＝ 沒真的啟用
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: nil, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: ["com.apple.FinalCut"], agentsWorking: false
        ,
            systemBusy: false
        ))
    }

    @Test("Agent mode follows the working flag and stays armed when agents go quiet")
    func agentBound() {
        let mode = KeepAwakeMode.whileAgentsWorking
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: true
        ,
            systemBusy: false
        ))
        // agent 收工就放掉 assertion，但模式留著——下一輪再開工要能自己恢復
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: false
        ,
            systemBusy: false
        ))
        // 沒有 startedAt ＝ 沒真的啟用
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: nil, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: true
        ,
            systemBusy: false
        ))
    }

    @Test("Agent mode blocks system sleep instead of display sleep, ignoring the toggle")
    func agentAssertionPlan() {
        for toggle in [true, false] {
            #expect(
                KeepAwakePlanner.assertionPlan(mode: .whileAgentsWorking, alsoPreventSystemSleep: toggle)
                    == KeepAwakeAssertionPlan(preventsDisplaySleep: false, preventsSystemSleep: true)
            )
        }
    }

    @Test("Every other mode keeps display sleep blocked and follows the toggle")
    func classicAssertionPlan() {
        let modes: [KeepAwakeMode] = [
            .off, .indefinite, .duration(seconds: 60),
            .whileDisplayConnected(uuid: "x"), .whileAppRunning(bundleID: "y"),
            .whileSystemBusy,
        ]
        for mode in modes {
            #expect(
                KeepAwakePlanner.assertionPlan(mode: mode, alsoPreventSystemSleep: false)
                    == KeepAwakeAssertionPlan(preventsDisplaySleep: true, preventsSystemSleep: false)
            )
            #expect(
                KeepAwakePlanner.assertionPlan(mode: mode, alsoPreventSystemSleep: true)
                    == KeepAwakeAssertionPlan(preventsDisplaySleep: true, preventsSystemSleep: true)
            )
        }
    }

    @Test("Load mode holds only with startedAt and systemBusy")
    func loadBound() {
        let mode = KeepAwakeMode.whileSystemBusy
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [],
            agentsWorking: false, systemBusy: true
        ))
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [],
            agentsWorking: false, systemBusy: false
        ))
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: nil, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [],
            agentsWorking: false, systemBusy: true
        ))
        #expect(KeepAwakePlanner.remainingSeconds(mode: mode, startedAt: 10, now: 30) == nil)
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
        #expect(KeepAwakePlanner.remainingSeconds(mode: .whileAgentsWorking, startedAt: 10, now: 30) == nil)
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
        #expect(
            KeepAwakePlanner.decode(KeepAwakePlanner.encode(.whileAgentsWorking)) == .indefinite
        )
        #expect(KeepAwakePlanner.encode(.whileSystemBusy) == -1)
        #expect(KeepAwakePlanner.decode(KeepAwakePlanner.encode(.whileSystemBusy)) == .indefinite)
    }

    @Test("Codable preserves the load mode case")
    func loadModeCodable() throws {
        let data = try JSONEncoder().encode(KeepAwakeMode.whileSystemBusy)
        let decoded = try JSONDecoder().decode(KeepAwakeMode.self, from: data)
        #expect(decoded == .whileSystemBusy)
    }
}
