import ChorusCore
import Foundation
import Testing
@testable import Chorus

@Suite("診斷快照")
struct DoctorInputsCollectorTests {
    @Test("TapEngine 狀態對應到診斷狀態")
    func tapStateMapping() {
        #expect(DoctorInputsCollector.tapState(.off) == (.off, nil))
        #expect(DoctorInputsCollector.tapState(.probing) == (.probing, nil))
        #expect(DoctorInputsCollector.tapState(.active) == (.active, nil))
        #expect(DoctorInputsCollector.tapState(.denied) == (.denied, nil))
        #expect(DoctorInputsCollector.tapState(.failed("boom")) == (.failed, "boom"))
    }

    @Test("V-C10-1 殘留時 doctor 為 warning；正常為 ok")
    func lidKeepAwakeLeftoverSeverity() {
        let status = PowerHelperStatus(
            helperBuild: "136",
            sleepDisabled: true,
            setByHelper: false,
            holderCount: 0
        )
        let withLeftover = DoctorInputsCollector.lidKeepAwakeSnapshot(
            phase: .off,
            helperAvailability: .ready,
            helperStatus: status,
            leftover: .foreign,
            reports: []
        )
        let warning = DoctorRules.evaluate(baseInputs(lid: withLeftover))
            .first { $0.id == "keepawake.lid" }
        #expect(warning?.status == .warning)
        #expect(warning?.title == "闔蓋防睡")
        #expect(warning?.detail?.contains("SleepDisabled=1") == true)
        #expect(warning?.detail?.contains("setByHelper=false") == true)
        #expect(warning?.remedy != nil)

        let clean = DoctorInputsCollector.lidKeepAwakeSnapshot(
            phase: .idle,
            helperAvailability: .ready,
            helperStatus: PowerHelperStatus(helperBuild: "136", sleepDisabled: false, setByHelper: false),
            leftover: nil,
            reports: [
                KeepAwakeSourceReport(
                    id: "agents", kind: .agentActivity, displayName: "Agents",
                    isWorkingNow: false, health: .ok
                ),
            ]
        )
        let ok = DoctorRules.evaluate(baseInputs(lid: clean))
            .first { $0.id == "keepawake.lid" }
        #expect(ok?.status == .ok)
        #expect(ok?.detail?.contains("殘留=無") == true)
        #expect(ok?.detail?.contains("agents=ok") == true)
        #expect(ok?.remedy == nil)
    }

    @Test("V-C10-1 recoveryBlocked 殘留亦為 warning")
    func recoveryBlockedIsWarning() {
        let snap = DoctorInputsCollector.lidKeepAwakeSnapshot(
            phase: .unavailable(.error("recoveryBlocked")),
            helperAvailability: .error("recoveryBlocked"),
            helperStatus: PowerHelperStatus(
                helperBuild: "136",
                sleepDisabled: true,
                setByHelper: true,
                recoveryBlocked: true
            ),
            leftover: .recoveryBlocked,
            reports: []
        )
        #expect(snap.leftover == "recoveryBlocked")
        #expect(snap.helperAvailability.hasPrefix("error("))
        let check = DoctorRules.evaluate(baseInputs(lid: snap))
            .first { $0.id == "keepawake.lid" }
        #expect(check?.status == .warning)
        #expect(check?.detail?.contains("帳本復原封鎖") == true)
    }

    @Test("V-C10-2 來源 reason 消毒 path／uid／pid／token")
    func sanitizesSourceReasons() {
        let snap = DoctorInputsCollector.lidKeepAwakeSnapshot(
            phase: .idle,
            helperAvailability: .ready,
            helperStatus: nil,
            leftover: nil,
            reports: [
                KeepAwakeSourceReport(
                    id: "orca",
                    kind: .orca,
                    displayName: "Orca",
                    isWorkingNow: false,
                    health: .degraded(
                        reason: "failed path=/Users/fi/.orca/bin uid=501 pid=4242 token=secret-value"
                    )
                ),
            ]
        )
        let reason = snap.sources.first?.reason ?? ""
        #expect(!reason.contains("/Users/"))
        #expect(!reason.contains("uid=501"))
        #expect(!reason.contains("pid=4242"))
        #expect(!reason.contains("secret-value"))
        #expect(reason.contains("<path>") || reason.contains("<redacted>"))
    }

    @Test("V1-8 helper availability tracks client state, not policy phase")
    func availabilityTracksHelperClient() {
        // Paused / blocked policy must not invent ready when helper is unregistered.
        let pausedUnregistered = DoctorInputsCollector.lidKeepAwakeSnapshot(
            phase: .blocked(.userPaused(untilUptime: 9_999)),
            helperAvailability: .notRegistered,
            helperStatus: nil,
            leftover: nil,
            reports: []
        )
        #expect(pausedUnregistered.helperAvailability == "notRegistered")

        let offWithStaleCache = DoctorInputsCollector.lidKeepAwakeSnapshot(
            phase: .off,
            helperAvailability: .notRegistered,
            helperStatus: PowerHelperStatus(helperBuild: "1", sleepDisabled: false),
            leftover: nil,
            reports: []
        )
        #expect(offWithStaleCache.helperAvailability == "notRegistered")

        let disconnected = DoctorInputsCollector.lidKeepAwakeSnapshot(
            phase: .armed,
            helperAvailability: .error("disconnected"),
            helperStatus: PowerHelperStatus(helperBuild: "1"),
            leftover: nil,
            reports: []
        )
        #expect(disconnected.helperAvailability.hasPrefix("error("))

        #expect(DoctorInputsCollector.availabilityWire(.requiresApproval) == "requiresApproval")
        #expect(DoctorInputsCollector.availabilityWire(.ready) == "ready")
    }

    @Test("chorus doctor JSON 含 keepawake.lid 項目")
    func doctorJSONContainsLidCheck() throws {
        let snap = DoctorInputsCollector.lidKeepAwakeSnapshot(
            phase: .idle,
            helperAvailability: .ready,
            helperStatus: PowerHelperStatus(helperBuild: "136", sleepDisabled: false),
            leftover: nil,
            reports: []
        )
        let report = DoctorReport(
            generatedAt: Date(timeIntervalSince1970: 0),
            checks: DoctorRules.evaluate(baseInputs(lid: snap))
        )
        let data = try JSONEncoder().encode(report)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("keepawake.lid"))
        #expect(text.contains("闔蓋防睡"))
    }

    private func baseInputs(lid: DoctorInputs.LidKeepAwake) -> DoctorInputs {
        DoctorInputs(
            browserState: "ready",
            listenerState: "ready",
            accessibilityTrusted: true,
            tapState: .active,
            tapError: nil,
            mainLoopResponsive: true,
            lastExitWasCrash: false,
            peers: [],
            lidKeepAwake: lid
        )
    }
}
