import ChorusCore
import Foundation
import Testing
@testable import Chorus

@Suite("Lid menu formatter (V-U02-1)")
struct LidMenuStatusFormatterTests {
    private let wallNow = Date(timeIntervalSince1970: 0)
    private func format(_ phase: LidSleepGuardPhase, confirmed: Bool = false, leftover: LeftoverSleepDisabled? = nil,
                        enabled: Bool = true, agent: Bool = true) -> LidMenuStatusFormatter.Presentation? {
        LidMenuStatusFormatter.format(phase: phase, enabled: enabled, agentModeActive: agent,
            confirmedHolding: confirmed, leftover: leftover, sources: [],
            nowUptime: 100, wallNow: wallNow, maxDurationSeconds: 10_800,
            releaseAt: nil, timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    @Test func everyPhaseHasExpectedSymbolAndAction() {
        let rows: [(LidSleepGuardPhase, String, LidMenuStatusFormatter.Action?)] = [
            (.unavailable(.requiresApproval), "exclamationmark.triangle", .allow),
            (.unavailable(.notRegistered), "exclamationmark.triangle", .manage),
            (.unavailable(.notFound), "exclamationmark.triangle", .manage),
            (.unavailable(.error("failure")), "exclamationmark.triangle", .manage),
            (.idle, "laptopcomputer", nil), (.armed, "laptopcomputer", .pause),
            (.holdingLidClosed(sinceUptime: 50), "laptopcomputer", .pause),
            (.blocked(.lowBattery(percent: 28, floor: 30)), "battery.25", nil),
            (.blocked(.lowBattery(percent: nil, floor: 30)), "battery.25", nil),
            (.blocked(.thermal), "thermometer.high", nil),
            (.blocked(.maxDuration(limitSeconds: 10_800)), "timer", nil),
            (.blocked(.userPaused(untilUptime: 160)), "pause.circle", .resume),
            (.blocked(.noLid), "laptopcomputer", nil),
            (.blocked(.lidUnknown), "questionmark.circle", nil),
            (.blocked(.unknownPower), "battery.0", nil),
        ]
        for (phase, symbol, action) in rows {
            let row = format(phase, confirmed: true)
            #expect(row?.symbol == symbol)
            #expect(row?.action == action)
            #expect(row?.text.isEmpty == false)
        }
        #expect(format(.off) == nil)
    }

    @Test func requestedHoldingIsPendingUntilHelperConfirms() {
        for phase: LidSleepGuardPhase in [.armed, .holdingLidClosed(sinceUptime: 50)] {
            let pending = format(phase)
            let held = format(phase, confirmed: true)
            #expect(pending?.text == String(localized: "正在啟用闔蓋防睡…"))
            #expect(pending?.showsHoldingBadge == false)
            #expect(held?.showsHoldingBadge == true)
            #expect(held?.text != pending?.text)
        }
    }

    @Test func foreignValueWithCallerHolderStillWarnsInsteadOfPendingForever() {
        let status = PowerHelperStatus(helperBuild: "140", sleepDisabled: true, setByHelper: false,
            holderCount: 1, callerIsHolder: true)
        let leftover = LidMenuStatusFormatter.visibleLeftover(nil, helperStatus: status)
        #expect(leftover == .foreign)
        #expect(format(.armed, leftover: leftover)?.action == .manage)
        #expect(format(.armed, leftover: leftover)?.showsHoldingBadge == false)
        #expect(LidMenuStatusFormatter.visibleLeftover(.otherUserHolding, helperStatus: status) == .otherUserHolding)
        #expect(LidMenuStatusFormatter.visibleLeftover(nil, helperStatus: nil) == nil)
        var recovered = status
        recovered.sleepDisabled = false
        recovered.pendingRestore = true
        #expect(LidMenuStatusFormatter.visibleLeftover(nil, helperStatus: recovered) == .recoveryBlocked)
    }

    @Test func offIsIdenticalToBaselineExceptRecoveryWarnings() {
        #expect(format(.armed, enabled: false) == nil)
        #expect(format(.armed, agent: false) == nil)
        for leftover: LeftoverSleepDisabled in [.foreign, .unknownOwner, .otherUserHolding, .ownResidual, .recoveryBlocked] {
            let row = format(.off, leftover: leftover, enabled: false, agent: false)
            #expect(row?.symbol == "exclamationmark.triangle")
            #expect(row?.action == .manage)
            #expect(row?.showsHoldingBadge == false)
        }
        #expect(format(.off, leftover: .otherUserHolding)?.text != format(.off, leftover: .foreign)?.text)
        #expect(format(.off, leftover: .recoveryBlocked)?.text != format(.off, leftover: .foreign)?.text)
    }

    @Test func countdownUsesInjectedTimeAndDoesNotResetDeadline() {
        let row = LidMenuStatusFormatter.format(phase: .holdingLidClosed(sinceUptime: 50), enabled: true,
            agentModeActive: true, confirmedHolding: true, leftover: nil, sources: [],
            nowUptime: 100, wallNow: wallNow, maxDurationSeconds: 180,
            releaseAt: nil, timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(row?.text.contains("2:10") == true)
        #expect(format(.blocked(.userPaused(untilUptime: 160)))?.text.contains("00:01") == true)
        #expect(format(.blocked(.lowBattery(percent: 28, floor: 30)))?.text.contains("28%") == true)
        #expect(format(.blocked(.lowBattery(percent: 28, floor: 30)))?.text.contains("30%") == true)
    }

    @Test func sourceSummaryCapsAtThreeAndHelpIncludesEveryDetailAndHealth() {
        let reports = (1...5).map { index in
            KeepAwakeSourceReport(id: "source\(index)", kind: .lease, displayName: "source\(index)",
                detail: "detail\(index)", isWorkingNow: true, health: .degraded(reason: "reason\(index)"))
        }
        let row = LidMenuStatusFormatter.format(phase: .armed, enabled: true, agentModeActive: true,
            confirmedHolding: true, leftover: nil, sources: reports, nowUptime: 100, wallNow: wallNow,
            maxDurationSeconds: 10_800, releaseAt: wallNow.addingTimeInterval(252), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(row?.text.contains("source3") == true)
        #expect(row?.text.contains("source4") == false)
        #expect(row?.text.contains("4:12") == true)
        for index in 1...5 {
            #expect(row?.help.contains("source\(index)") == true)
            #expect(row?.help.contains("detail\(index)") == true)
            #expect(row?.help.contains("reason\(index)") == true)
        }
    }
}
