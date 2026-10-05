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
            peers: sync.doctorPeers(policy: appState.pairedPeers.policy(for:))
        )
        return DoctorReport(generatedAt: Date(), checks: DoctorRules.evaluate(inputs))
    }
}
