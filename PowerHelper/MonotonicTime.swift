import Darwin
import Foundation

/// Boot-anchored continuous time for helper + lid deadline (spec §14.2 / W1-10).
/// Advances across sleep; does not reset on process restart within the same boot.
enum MonotonicTime {
    /// One continuous Darwin clock for every deadline; never switch to systemUptime.
    static func seconds() -> Double {
        var timebase = mach_timebase_info_data_t()
        let result = mach_timebase_info(&timebase)
        precondition(result == KERN_SUCCESS && timebase.denom != 0, "Continuous clock unavailable")
        return Double(mach_continuous_time()) * Double(timebase.numer) /
            Double(timebase.denom) / 1_000_000_000.0
    }

    /// Same-boot identity for persisted deadlines. nil → treat persistence as invalid.
    static func bootSessionUUID() -> String? {
        var size = 0
        sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0)
        guard size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(size))
        let rc = sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0)
        guard rc == 0 else { return nil }
        return String(cString: buffer)
    }
}
