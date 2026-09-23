import Foundation
import Testing
@testable import ChorusCore

@Suite("SystemLoad model")
struct SystemLoadTests {
    @Test func cpuDeltaIsNormalizedAcrossAllTicks() {
        let before = CPUTicks(user: 100, system: 100, nice: 0, idle: 800)
        let after = CPUTicks(user: 150, system: 150, nice: 0, idle: 900)
        #expect(SystemLoadDelta.cpu(previous: before, current: after) == 50)
    }

    @Test func cpuDeltaRejectsRegressionAndZeroTotal() {
        let base = CPUTicks(user: 100, system: 100, nice: 0, idle: 800)
        let lower = CPUTicks(user: 90, system: 100, nice: 0, idle: 800)
        #expect(SystemLoadDelta.cpu(previous: base, current: lower) == nil)

        let same = CPUTicks(user: 100, system: 100, nice: 0, idle: 800)
        #expect(SystemLoadDelta.cpu(previous: base, current: same) == nil)
    }

    @Test func networkDeltaFiveSecondsFiveMiBIsOneMiBPerSecond() {
        let before = [NetworkInterfaceCounters(index: 1, name: "en0", received: 0, sent: 0)]
        let after = [NetworkInterfaceCounters(
            index: 1, name: "en0",
            received: 2_621_440, sent: 2_621_440
        )]
        #expect(SystemLoadDelta.network(previous: before, current: after, elapsed: 5) == 1_048_576)
    }

    @Test func networkDeltaHandlesInterfaceChurnAndEmpty() {
        let previous = [
            NetworkInterfaceCounters(index: 1, name: "en0", received: 100, sent: 100),
        ]
        // Only a brand-new interface → no comparable baseline.
        let onlyNew = [
            NetworkInterfaceCounters(index: 2, name: "en1", received: 1_000_000, sent: 0),
        ]
        #expect(SystemLoadDelta.network(previous: previous, current: onlyNew, elapsed: 5) == nil)

        // Empty current → 0 (no online physical interfaces).
        #expect(SystemLoadDelta.network(previous: previous, current: [], elapsed: 5) == 0)

        // Removed en0, added en1 with prior en0 gone: only new → nil
        let replaced = [
            NetworkInterfaceCounters(index: 1, name: "en0", received: 200, sent: 200),
            NetworkInterfaceCounters(index: 3, name: "en2", received: 50, sent: 50),
        ]
        let next = [
            NetworkInterfaceCounters(index: 1, name: "en0", received: 300, sent: 300),
            NetworkInterfaceCounters(index: 4, name: "en3", received: 0, sent: 0),
        ]
        // en0 comparable (+200 bytes), en3 new ignored → 200/5 = 40
        #expect(SystemLoadDelta.network(previous: replaced, current: next, elapsed: 5) == 40)

        // Index reuse with different name is a different key.
        let reusedIndex = [
            NetworkInterfaceCounters(index: 1, name: "en9", received: 10_000, sent: 0),
        ]
        #expect(SystemLoadDelta.network(previous: previous, current: reusedIndex, elapsed: 5) == nil)

        // Counter regression on one iface skips it; other comparable iface still counts.
        let multiPrev = [
            NetworkInterfaceCounters(index: 1, name: "en0", received: 1_000, sent: 0),
            NetworkInterfaceCounters(index: 2, name: "en1", received: 500, sent: 0),
        ]
        let multiNext = [
            NetworkInterfaceCounters(index: 1, name: "en0", received: 100, sent: 0), // regress
            NetworkInterfaceCounters(index: 2, name: "en1", received: 1_500, sent: 0), // +1000
        ]
        #expect(SystemLoadDelta.network(previous: multiPrev, current: multiNext, elapsed: 5) == 200)
    }

    @Test func networkDeltaAvoidsSumOverflowByDifferencingFirst() {
        let nearMax = UInt64.max - 100
        let previous = [
            NetworkInterfaceCounters(index: 1, name: "en0", received: nearMax, sent: nearMax),
            NetworkInterfaceCounters(index: 2, name: "en1", received: nearMax, sent: nearMax),
        ]
        let current = [
            NetworkInterfaceCounters(index: 1, name: "en0", received: nearMax + 50, sent: nearMax + 50),
            NetworkInterfaceCounters(index: 2, name: "en1", received: nearMax + 50, sent: nearMax + 50),
        ]
        // 4 * 50 = 200 bytes over 2 seconds → 100 B/s
        #expect(SystemLoadDelta.network(previous: previous, current: current, elapsed: 2) == 100)
    }

    @Test func configurationJSONRoundTripAndInvalidFallback() {
        let original = SystemLoadConfiguration.default
        let data = try! JSONEncoder().encode(original)
        let decoded = try! JSONDecoder().decode(SystemLoadConfiguration.self, from: data)
        #expect(decoded == original)

        var invalid = SystemLoadConfiguration.default
        invalid.cpu.activation = 10
        invalid.cpu.release = 50
        #expect(!invalid.isValid)
        #expect(invalid.normalized() == .default)

        invalid = .default
        invalid.cpuEnabled = false
        invalid.gpuEnabled = false
        invalid.networkEnabled = false
        #expect(!invalid.isValid)

        invalid = .default
        invalid.activationSeconds = 7
        #expect(!invalid.isValid)

        invalid = .default
        invalid.network.activation = 100
        #expect(!invalid.isValid)

        invalid = .default
        invalid.cpu.activation = .nan
        #expect(!invalid.isValid)
    }
}
