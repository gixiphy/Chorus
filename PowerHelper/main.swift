import ChorusCore
import Foundation

#if DEBUG
private let isReleaseBuild = false
#else
private let isReleaseBuild = true
#endif

private let helperBuild =
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    ?? ProcessInfo.processInfo.environment["CHORUS_HELPER_BUILD"]
    ?? "0"

private let service = PowerHelperService(
    runner: PMSetRunner(),
    store: LedgerStore(),
    safety: HelperPowerSafety(),
    helperBuild: helperBuild,
    isRelease: isReleaseBuild
)

private let delegate = PowerHelperListenerDelegate(service: service)
private let listener = NSXPCListener(machServiceName: PowerHelperConstants.machServiceName)

// Dual code-signing: verify the App before accepting any connection (spec §6.3).
// Release installs the Developer ID + no get-task-allow requirement (Fi A6).
listener.setConnectionCodeSigningRequirement(service.clientRequirementString)
listener.delegate = delegate

service.start()
listener.resume()
RunLoop.main.run()
