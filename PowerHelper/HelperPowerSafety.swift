import Foundation
import IOKit.ps

/// Helper hard floor: thermal critical or battery < 10% (spec §6.3).
/// Unknown power / unknown thermal → refuse (Fi A3 / §14.1).
struct HelperSafetySnapshot: Equatable, Sendable {
    enum Thermal: Equatable, Sendable {
        case nominal
        case fair
        case serious
        case critical
        case unknown
    }

    var thermal: Thermal
    /// nil = unknown power/capability (refuse).
    var onBattery: Bool?
    /// nil when unknown or not applicable.
    var batteryPercent: Int?

    var refusesAcquire: RefuseReason? {
        if thermal == .critical || thermal == .unknown {
            return .thermal
        }
        guard let onBattery else {
            return .battery // unknown power → refuse
        }
        if onBattery {
            guard let percent = batteryPercent else { return .battery }
            if percent < 10 { return .battery }
        }
        return nil
    }

    enum RefuseReason: String, Sendable {
        case thermal
        case battery

        var errorCode: String {
            switch self {
            case .thermal: return "refusedThermal"
            case .battery: return "refusedBattery"
            }
        }

        var forcedOffReason: String {
            switch self {
            case .thermal: return "thermalCritical"
            case .battery: return "batteryCritical"
            }
        }
    }
}

protocol HelperPowerSafetyChecking: AnyObject, Sendable {
    func snapshot() -> HelperSafetySnapshot
}

final class HelperPowerSafety: HelperPowerSafetyChecking, @unchecked Sendable {
    private let readSnapshot: () -> HelperSafetySnapshot

    init(readSnapshot: @escaping () -> HelperSafetySnapshot = HelperPowerSafety.readSystemSnapshot) {
        self.readSnapshot = readSnapshot
    }

    func snapshot() -> HelperSafetySnapshot {
        var snap = readSnapshot()
        #if DEBUG
        if HelperPowerSafety.debugForceCriticalFileExists() {
            snap.thermal = .critical
        }
        #endif
        return snap
    }

    /// DEBUG-only external switch for M-12d. Release builds must not consult any path (S-5).
    #if DEBUG
    static let debugForceCriticalPath =
        "/Library/Application Support/com.hermes.Chorus.PowerHelper/debug-force-critical"

    static func debugForceCriticalFileExists() -> Bool {
        FileManager.default.fileExists(atPath: debugForceCriticalPath)
    }
    #endif

    static func readSystemSnapshot() -> HelperSafetySnapshot {
        let thermal: HelperSafetySnapshot.Thermal
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = .nominal
        case .fair: thermal = .fair
        case .serious: thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .unknown
        }

        let power = readBattery()
        return HelperSafetySnapshot(
            thermal: thermal,
            onBattery: power.onBattery,
            batteryPercent: power.percent
        )
    }

    private static func readBattery() -> (onBattery: Bool?, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return (nil, nil)
        }

        var sawInternalBattery = false
        var percent: Int?
        var anyPowerSource = false

        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            anyPowerSource = true
            let type = desc[kIOPSTypeKey] as? String
            if type == kIOPSInternalBatteryType {
                sawInternalBattery = true
                if let capacity = desc[kIOPSCurrentCapacityKey] as? Int {
                    percent = capacity
                } else if let capacity = desc[kIOPSCurrentCapacityKey] as? Double {
                    percent = Int(capacity)
                }
            }
        }

        if !anyPowerSource {
            // Desktop with no battery entries: treat as known AC (onBattery=false).
            return (false, nil)
        }

        if sawInternalBattery {
            let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
            let onBattery = providing == kIOPSBatteryPowerValue
            return (onBattery, percent)
        }

        // Power sources present but no internal battery → AC.
        return (false, nil)
    }
}
