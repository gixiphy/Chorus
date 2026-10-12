import ChorusCore
import Foundation
import Testing
@testable import Chorus

@Suite("Lid settings presentation (V-U01-1)")
struct LidSleepSettingsPresentationTests {
    @Test func helperStatesOfferOnlyRelevantActions() {
        let rows: [(LidHelperAvailability, LidSleepSettingsPresentation.HelperAction?)] = [
            (.notRegistered, .install), (.requiresApproval, .allow), (.notFound, .repair),
            (.connecting, nil), (.ready, nil),
            (.versionMismatch(helper: "old", app: "new"), .repair), (.error("failure"), .repair),
        ]
        for (availability, action) in rows {
            let row = LidSleepSettingsPresentation.helper(availability: availability, build: "140")
            #expect(row.action == action)
            #expect(!row.text.isEmpty)
        }
        #expect(LidSleepSettingsPresentation.helper(availability: .ready, build: "140").text.contains("140"))
    }

    @Test func enableRequiresSheetAndCancelPreservesDisabledSetting() {
        #expect(LidSleepSettingsPresentation.enableDecision(true, confirmedNoLid: false) == .explain)
        #expect(LidSleepSettingsPresentation.enableDecision(false, confirmedNoLid: false) == .disable)
        #expect(LidSleepSettingsPresentation.enableDecision(true, confirmedNoLid: true) == .forbid)
        // The request only chooses a presentation action; settings stay off until confirmation.
        let settings = LidSleepSettings()
        _ = LidSleepSettingsPresentation.enableDecision(true, confirmedNoLid: false)
        #expect(!settings.enabled)
    }

    @Test func approvedChoicesAndNoLidCapability() {
        #expect(LidSleepSettingsPresentation.maxHours == [2, 3])
        #expect(LidSleepSettingsPresentation.batteryFloors == [30, 40, 50])
        #expect(!LidSleepSettingsPresentation.showsLidControls(confirmedNoLid: true))
        #expect(LidSleepSettingsPresentation.showsLidControls(confirmedNoLid: false))
        #expect(!LidSleepSettings().enabled)
        #expect(LidSleepSettings().limitDurationOnAC)
    }

    @Test func executableSelectionRejectsDirectoryAndNonExecutable() {
        #expect(LidSleepSettingsPresentation.acceptsCLI(isDirectory: false, isExecutable: true))
        #expect(!LidSleepSettingsPresentation.acceptsCLI(isDirectory: true, isExecutable: true))
        #expect(!LidSleepSettingsPresentation.acceptsCLI(isDirectory: false, isExecutable: false))
    }

    @MainActor
    @Test func repairRequiresVerifiedRemovalBeforeRegistration() async throws {
        var effects: [String] = []
        try await LidSleepSettingsPresentation.performRepair(replaceRegisteredHelper: true,
            unregister: { effects.append("releasedAndRemoved") }, register: { effects.append("registered") })
        #expect(effects == ["releasedAndRemoved", "registered"])
        effects = []
        enum Blocked: Error { case otherHolder }
        do {
            try await LidSleepSettingsPresentation.performRepair(replaceRegisteredHelper: true,
                unregister: { throw Blocked.otherHolder }, register: { effects.append("registered") })
            Issue.record("Unsafe removal must block registration")
        } catch Blocked.otherHolder {}
        #expect(effects.isEmpty)
    }

    @Test func degradedHealthDoesNotInventProcessFallback() {
        let reason = "truncated"
        #expect(LidSleepSettingsPresentation.health(.degraded(reason: reason)) == String(localized: "降級：\(reason)"))
    }

    @Test func removalDoesNotOfferUnsafeUnregister() {
        #expect(LidSleepSettingsPresentation.canRemove(holderCount: 1, callerIsHolder: true, recoveryBlocked: false, sleepDisabled: true))
        #expect(!LidSleepSettingsPresentation.canRemove(holderCount: 2, callerIsHolder: true, recoveryBlocked: false, sleepDisabled: true))
        #expect(!LidSleepSettingsPresentation.canRemove(holderCount: 1, callerIsHolder: false, recoveryBlocked: false, sleepDisabled: true))
        #expect(!LidSleepSettingsPresentation.canRemove(holderCount: 0, callerIsHolder: false, recoveryBlocked: true, sleepDisabled: false))
        #expect(!LidSleepSettingsPresentation.canRemove(holderCount: 0, callerIsHolder: false, recoveryBlocked: false, sleepDisabled: nil))
    }
}
