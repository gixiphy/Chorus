import ChorusCore
import Foundation
import IOKit

struct SystemGPUReadResult: Sendable {
    let reading: SystemLoadReading
    let partialSupport: Bool
}

struct SystemGPUReader: Sendable {
    /// Probe GPU utilization via IOKit. `previouslyUnsupported` skips re-walk until
    /// forced (mode restart / wake / topology change).
    func read(forceProbe: Bool = false, previouslyUnsupported: Bool = false) -> SystemGPUReadResult {
        if previouslyUnsupported && !forceProbe {
            return SystemGPUReadResult(reading: .unsupported, partialSupport: false)
        }

        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("AGXAccelerator") else {
            return SystemGPUReadResult(reading: .unsupported, partialSupport: false)
        }
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            return SystemGPUReadResult(reading: .unavailable, partialSupport: false)
        }
        defer { IOObjectRelease(iterator) }

        var readableValues: [Double] = []
        var sawDevice = false
        var unreadableCount = 0

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            sawDevice = true
            guard let stats = IORegistryEntryCreateCFProperty(
                service,
                "PerformanceStatistics" as CFString,
                kCFAllocatorDefault,
                0
            )?.takeRetainedValue() as? [String: Any]
            else {
                unreadableCount += 1
                continue
            }
            if let value = Self.utilization(statistics: stats) {
                readableValues.append(value)
            } else {
                unreadableCount += 1
            }
        }

        if !sawDevice {
            return SystemGPUReadResult(reading: .unsupported, partialSupport: false)
        }
        if readableValues.isEmpty {
            return SystemGPUReadResult(reading: .unsupported, partialSupport: false)
        }

        return SystemGPUReadResult(
            reading: .value(readableValues.max() ?? 0),
            partialSupport: unreadableCount > 0
        )
    }

    /// Pure parser seam for fixture tests. Rejects Bool / CFBoolean and out-of-range values.
    static func utilization(statistics: [String: Any]) -> Double? {
        guard let raw = statistics["Device Utilization %"] else { return nil }
        if raw is Bool { return nil }
        if CFGetTypeID(raw as CFTypeRef) == CFBooleanGetTypeID() { return nil }

        if let number = raw as? NSNumber {
            let value = number.doubleValue
            guard value.isFinite, (0...100).contains(value) else { return nil }
            return value
        }
        if let value = raw as? Int {
            guard (0...100).contains(value) else { return nil }
            return Double(value)
        }
        if let value = raw as? Double {
            guard value.isFinite, (0...100).contains(value) else { return nil }
            return value
        }
        return nil
    }
}
