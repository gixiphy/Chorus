import Foundation
import Testing
@testable import ChorusCore

@Suite("KeepAwakePlanner")
struct KeepAwakeTests {
    @Test("Off never holds an assertion")
    func off() {
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: .off, startedAt: 100, now: 100,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: false, systemBusy: false,
            powerFloorTripped: false
        ))
    }

    @Test("Timed mode expires exactly at the duration")
    func timedExpiry() {
        let mode = KeepAwakeMode.duration(seconds: 1800)
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 100, now: 100 + 1799,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: false, systemBusy: false,
            powerFloorTripped: false
        ))
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 100, now: 100 + 1800,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: false, systemBusy: false,
            powerFloorTripped: false
        ))
    }

    @Test("Indefinite holds until explicitly turned off")
    func indefinite() {
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: .indefinite, startedAt: 0, now: 999_999,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: false, systemBusy: false,
            powerFloorTripped: false
        ))
        // 沒有 startedAt ＝ 沒真的啟用
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: .indefinite, startedAt: nil, now: 10,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [], agentsWorking: false, systemBusy: false,
            powerFloorTripped: false
        ))
    }

    @Test("Display-bound mode drops the assertion when that display is unplugged")
    func displayBound() {
        let mode = KeepAwakeMode.whileDisplayConnected(uuid: "AOC")
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: ["AOC", "builtin"], runningAppBundleIDs: [], agentsWorking: false, systemBusy: false,
            powerFloorTripped: false
        ))
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: ["builtin"], runningAppBundleIDs: [], agentsWorking: false, systemBusy: false,
            powerFloorTripped: false
        ))
    }

    @Test("App-bound mode follows the app in and out of the running set")
    func appBound() {
        let mode = KeepAwakeMode.whileAppRunning(bundleID: "com.apple.FinalCut")
        #expect(KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: [],
            runningAppBundleIDs: ["com.apple.FinalCut", "com.apple.finder"], agentsWorking: false, systemBusy: false,
            powerFloorTripped: false
        ))
        // App 關掉就失效，但模式留著——再開時要能自己恢復
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: ["com.apple.finder"], agentsWorking: false, systemBusy: false,
            powerFloorTripped: false
        ))
        // 沒有 startedAt ＝ 沒真的啟用
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: nil, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: ["com.apple.FinalCut"], agentsWorking: false, systemBusy: false,
            powerFloorTripped: false
        ))
    }

    @Test("Merged mode ORs agent and load busy")
    func mergedORTruthTable() {
        let mode = KeepAwakeMode.whileAgentsWorking
        let cases: [(Bool, Bool, Bool)] = [
            (false, false, false),
            (true, false, true),
            (false, true, true),
            (true, true, true),
        ]
        for (agents, load, expected) in cases {
            #expect(
                KeepAwakePlanner.shouldHoldAssertion(
                    mode: mode, startedAt: 0, now: 50,
                    connectedDisplayUUIDs: [], runningAppBundleIDs: [],
                    agentsWorking: agents, systemBusy: load,
                    powerFloorTripped: false
                ) == expected
            )
        }
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: 0, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [],
            agentsWorking: true, systemBusy: true,
            powerFloorTripped: true
        ))
        #expect(!KeepAwakePlanner.shouldHoldAssertion(
            mode: mode, startedAt: nil, now: 50,
            connectedDisplayUUIDs: [], runningAppBundleIDs: [],
            agentsWorking: true, systemBusy: true,
            powerFloorTripped: false
        ))
    }

    @Test("Merged mode keeps both the display and system awake, ignoring the toggle")
    func agentAssertionPlan() {
        for toggle in [true, false] {
            #expect(
                KeepAwakePlanner.assertionPlan(mode: .whileAgentsWorking, alsoPreventSystemSleep: toggle)
                    == KeepAwakeAssertionPlan(preventsDisplaySleep: true, preventsSystemSleep: true)
            )
        }
    }

    @Test("Every other mode keeps display sleep blocked and follows the toggle")
    func classicAssertionPlan() {
        let modes: [KeepAwakeMode] = [
            .off, .indefinite, .duration(seconds: 60),
            .whileDisplayConnected(uuid: "x"), .whileAppRunning(bundleID: "y"),
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
        #expect(KeepAwakePlanner.encode(.whileAgentsWorking) == -1)
    }

    @Test("Legacy whileSystemBusy JSON decodes as whileAgentsWorking")
    func legacyLoadModeDecodable() throws {
        let legacy = Data(#"{"whileSystemBusy":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(KeepAwakeMode.self, from: legacy)
        #expect(decoded == .whileAgentsWorking)

        let roundTrip = try JSONDecoder().decode(
            KeepAwakeMode.self,
            from: try JSONEncoder().encode(KeepAwakeMode.whileAgentsWorking)
        )
        #expect(roundTrip == .whileAgentsWorking)
    }

    @Test("All historical KeepAwakeMode JSON shapes still decode")
    func allLegacyCasesDecodable() throws {
        let fixtures: [(String, KeepAwakeMode)] = [
            (#"{"off":{}}"#, .off),
            (#"{"indefinite":{}}"#, .indefinite),
            (#"{"duration":{"seconds":1800}}"#, .duration(seconds: 1800)),
            (#"{"whileDisplayConnected":{"uuid":"A"}}"#, .whileDisplayConnected(uuid: "A")),
            (#"{"whileAppRunning":{"bundleID":"com.x"}}"#, .whileAppRunning(bundleID: "com.x")),
            (#"{"whileAgentsWorking":{}}"#, .whileAgentsWorking),
            (#"{"whileSystemBusy":{}}"#, .whileAgentsWorking),
        ]
        for (json, expected) in fixtures {
            let decoded = try JSONDecoder().decode(KeepAwakeMode.self, from: Data(json.utf8))
            #expect(decoded == expected)
        }
    }

    @Test("FocusSnapshot with legacy whileSystemBusy keepAwake still decodes")
    func focusSnapshotLegacyKeepAwake() throws {
        let json = Data(#"{"requests":[],"unrestorable":[],"keepAwake":{"whileSystemBusy":{}}}"#.utf8)
        let snapshot = try JSONDecoder().decode(FocusSnapshot.self, from: json)
        #expect(snapshot.keepAwake == .whileAgentsWorking)
    }
}
