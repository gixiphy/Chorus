import Darwin
import Foundation

/// Boot-anchored continuous time for helper + lid deadline (spec §14.2 / W1-10).
/// Advances across sleep; does not reset on process restart within the same boot.
enum MonotonicTime {
    /// Seconds from `CLOCK_MONOTONIC_RAW` (continues across sleep on Darwin).
    static func seconds() -> Double {
        var ts = timespec()
        let rc = clock_gettime(CLOCK_MONOTONIC_RAW, &ts)
        guard rc == 0 else {
            // Conservative fallback — still monotonic within process.
            return ProcessInfo.processInfo.systemUptime
        }
        return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000.0
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
