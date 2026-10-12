import ApplicationServices
import ChorusCore
import Foundation

/// 從 App 現況組出 `DoctorInputs`。只讀，不觸發任何權限對話框。
enum DoctorInputsCollector {
    static func tapState(_ state: TapEngine.State) -> (DoctorInputs.TapState, String?) {
        switch state {
        case .off: (.off, nil)
        case .probing: (.probing, nil)
        case .active: (.active, nil)
        case .denied: (.denied, nil)
        case let .failed(message): (.failed, message)
        }
    }

    @MainActor
    static func report(appState: AppState) -> DoctorReport {
        let (tap, tapError) = tapState(appState.tapEngine.state)
        let sync = appState.sessionManager
        let inputs = DoctorInputs(
            browserState: sync.browserStateDescription,
            listenerState: sync.listenerStateDescription,
            accessibilityTrusted: AXIsProcessTrusted(),
            tapState: tap,
            tapError: tapError,
            mainLoopResponsive: AutomationHTTPTransport.mainLoopResponsive(),
            lastExitWasCrash: CrashReportCollector.shared.snapshot().unacknowledged != nil,
            peers: sync.doctorPeers(policy: appState.pairedPeers.policy(for:)),
            lidKeepAwake: lidKeepAwakeSnapshot(from: appState.keepAwake)
        )
        return DoctorReport(generatedAt: Date(), checks: DoctorRules.evaluate(inputs))
    }

    // MARK: - Lid keep-awake（spec §8.4／V-C10-*）

    /// 純函式：由 controller 快照組出 doctor 輸入（可測、不碰 XPC）。
    static func lidKeepAwakeSnapshot(
        phase: LidSleepGuardPhase,
        helperStatus: PowerHelperStatus?,
        leftover: LeftoverSleepDisabled?,
        reports: [KeepAwakeSourceReport]
    ) -> DoctorInputs.LidKeepAwake {
        DoctorInputs.LidKeepAwake(
            helperAvailability: helperAvailabilityWire(
                phase: phase,
                helperStatus: helperStatus,
                leftover: leftover
            ),
            sleepDisabled: helperStatus?.sleepDisabled,
            setByHelper: helperStatus.map(\.setByHelper),
            leftover: leftover.map(leftoverWire),
            sources: reports.map { report in
                let (health, reason) = healthWire(report.health)
                return .init(id: report.id, health: health, reason: reason)
            }
        )
    }

    @MainActor
    static func lidKeepAwakeSnapshot(from keepAwake: KeepAwakeController) -> DoctorInputs.LidKeepAwake {
        let lid = keepAwake.lidGuard
        return lidKeepAwakeSnapshot(
            phase: lid.phase,
            helperStatus: lid.helperStatus,
            leftover: lid.leftover,
            reports: keepAwake.sourceHub.reports
        )
    }

    static func leftoverWire(_ leftover: LeftoverSleepDisabled) -> String {
        switch leftover {
        case .ownResidual: "ownResidual"
        case .foreign: "foreign"
        case .otherUserHolding: "otherUserHolding"
        case .unknownOwner: "unknownOwner"
        case .recoveryBlocked: "recoveryBlocked"
        }
    }

    /// C08 未公開 `helper.availability`；依 phase／helperStatus／leftover 推導（交接紀錄註明）。
    static func helperAvailabilityWire(
        phase: LidSleepGuardPhase,
        helperStatus: PowerHelperStatus?,
        leftover: LeftoverSleepDisabled?
    ) -> String {
        switch phase {
        case let .unavailable(availability):
            return availabilityWire(availability)
        case .armed, .holdingLidClosed, .idle, .blocked:
            return "ready"
        case .off:
            if helperStatus != nil { return "ready" }
            if leftover == .unknownOwner { return "unavailable" }
            return "notRegistered"
        }
    }

    static func availabilityWire(_ availability: LidHelperAvailability) -> String {
        switch availability {
        case .notRegistered: "notRegistered"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        case .connecting: "connecting"
        case .ready: "ready"
        case let .versionMismatch(helper, app):
            "versionMismatch(helper=\(helper),app=\(app))"
        case let .error(message):
            "error(\(sanitizeDoctorText(message)))"
        }
    }

    static func healthWire(_ health: KeepAwakeSourceHealth) -> (String, String?) {
        switch health {
        case .ok:
            return ("ok", nil)
        case let .degraded(reason):
            return ("degraded", sanitizeDoctorText(reason))
        case let .unavailable(reason):
            return ("unavailable", sanitizeDoctorText(reason))
        }
    }

    /// 診斷／doctor 共用消毒：去掉 path、uid、pid、token 樣式（V-C10-2／§14.3）。
    static func sanitizeDoctorText(_ text: String) -> String {
        var result = text
        let patterns: [(String, String)] = [
            (#"(?i)\buid[=:\s]+\d+"#, "uid=<redacted>"),
            (#"(?i)\bpid[=:\s]+\d+"#, "pid=<redacted>"),
            (#"(?i)\btoken[=:\s]+\S+"#, "token=<redacted>"),
            (#"(?:~|/|\./|\.\./)[^\s,;）)]+"#, "<path>"),
        ]
        for (pattern, replacement) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }
}
