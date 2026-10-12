import Foundation
import IOKit.ps

/// Helper hard floor: thermal critical or battery < 10% (spec §6.3).
/// Unknown power / unknown thermal → refuse (Fi A3 / §14.1 / W1-7).
struct HelperSafetySnapshot: Equatable, Sendable {
    enum Thermal: Equatable, Sendable {
        case nominal
        case fair
        case serious
        case critical
        case unknown
    }

    var thermal: Thermal
    /// nil = unknown power/capability (refuse). false = confirmed AC. true = confirmed battery.
    var onBattery: Bool?
    /// nil when unknown or not applicable. Finite 0…100 when known.
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

    /// Pure classification for tests (W1-7).
    static func classifyPowerSources(
        descriptions: [[String: Any]],
        providingType: String?
    ) -> (onBattery: Bool?, percent: Int?) {
        if descriptions.isEmpty {
            // Empty list is not confirmed desktop AC — could be a read failure (W1-7).
            return (nil, nil)
        }

        var sawInternalBattery = false
        var percent: Int?
        var parsedAny = false

        for desc in descriptions {
            parsedAny = true
            let type = desc[kIOPSTypeKey] as? String
            if type == kIOPSInternalBatteryType {
                sawInternalBattery = true
                percent = normalizedCapacityPercent(desc)
            }
        }

        guard parsedAny else {
            return (nil, nil)
        }

        if sawInternalBattery {
            return (classifyProviding(providingType), percent)
        }

        // Power sources present, no internal battery → confirmed AC only when providing is known AC/UPS.
        switch classifyProviding(providingType) {
        case .some(false):
            return (false, nil)
        case .some(true):
            // Providing claims battery but no internal battery entry → unknown.
            return (nil, nil)
        case .none:
            // Unrecognized / nil providing with no battery: still unknown (not assumed AC).
            return (nil, nil)
        }
    }

    /// nil providing or unrecognized string → unknown (not AC).
    static func classifyProviding(_ providing: String?) -> Bool? {
        guard let providing else { return nil }
        if providing == kIOPSBatteryPowerValue { return true }
        if providing == kIOPSACPowerValue { return false }
        // kIOPSOffLineValue and anything else → unknown (refuse).
        return nil
    }

    /// Prefer Current/Max when both are valid; never treat malformed max as "use current as %".
    /// Clamp the finite Double into 0…100 **before** Int conversion (W1-7: huge ratios must not trap).
    static func normalizedCapacityPercent(_ desc: [String: Any]) -> Int? {
        let current = finiteNumber(desc[kIOPSCurrentCapacityKey])
        let maxRaw = desc[kIOPSMaxCapacityKey]
        let maxPresent = maxRaw != nil
        let maxCapacity = finiteNumber(maxRaw)

        if maxPresent {
            // Malformed / nonfinite / non-positive max → unknown (do not fall back to current%).
            guard let maxCapacity, maxCapacity > 0, let current, current.isFinite, current >= 0 else {
                return nil
            }
            let ratio = (current / maxCapacity) * 100
            guard ratio.isFinite else { return nil }
            let clamped = Swift.min(100.0, Swift.max(0.0, ratio))
            return Int(clamped.rounded())
        }

        if let current {
            // Some IOKit samples already report 0…100 in CurrentCapacity when Max is absent.
            if current >= 0, current <= 100 {
                return Int(current.rounded())
            }
        }
        return nil
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        if let n = value as? Double, n.isFinite { return n }
        if let n = value as? Float, n.isFinite { return Double(n) }
        if let n = value as? Int { return Double(n) }
        if let n = value as? NSNumber {
            let d = n.doubleValue
            return d.isFinite ? d : nil
        }
        return nil
    }

    private static func readBattery() -> (onBattery: Bool?, percent: Int?) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return (nil, nil)
        }

        var descriptions: [[String: Any]] = []
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            else { continue }
            descriptions.append(desc)
        }

        // All description lookups failed → unknown, never assume AC (W1-7).
        if !list.isEmpty, descriptions.isEmpty {
            return (nil, nil)
        }

        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return classifyPowerSources(descriptions: descriptions, providingType: providing)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
