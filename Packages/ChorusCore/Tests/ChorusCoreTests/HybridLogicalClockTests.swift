import Testing
@testable import ChorusCore

@Suite("HybridLogicalClock")
struct HybridLogicalClockTests {
    @Test("next() is strictly monotonic even with a frozen wall clock")
    func monotonicWithFrozenClock() {
        var generator = HLCGenerator(peerID: "A")
        var previous = generator.next(wallNowMicros: 1000)
        for _ in 0..<100 {
            let next = generator.next(wallNowMicros: 1000)
            #expect(next > previous)
            previous = next
        }
    }

    @Test("next() is monotonic when the wall clock goes backwards")
    func monotonicWithBackwardClock() {
        var generator = HLCGenerator(peerID: "A")
        let first = generator.next(wallNowMicros: 5000)
        let second = generator.next(wallNowMicros: 3000)
        #expect(second > first)
        #expect(second.wallMicros == 5000)
    }

    @Test("observe() keeps local clock ahead of remote events")
    func observeAdvancesPastRemote() {
        var generator = HLCGenerator(peerID: "A")
        _ = generator.next(wallNowMicros: 1000)
        // 遠端時鐘快很多
        let remote = HLCTimestamp(wallMicros: 9000, counter: 5, peerID: "B")
        generator.observe(remote, wallNowMicros: 1001)
        let next = generator.next(wallNowMicros: 1002)
        #expect(next > remote)
    }

    @Test("Comparison is total: wall, then counter, then peerID")
    func comparisonOrder() {
        let base = HLCTimestamp(wallMicros: 100, counter: 1, peerID: "B")
        #expect(HLCTimestamp(wallMicros: 99, counter: 9, peerID: "Z") < base)
        #expect(HLCTimestamp(wallMicros: 100, counter: 0, peerID: "Z") < base)
        #expect(HLCTimestamp(wallMicros: 100, counter: 1, peerID: "A") < base)
        #expect(!(base < base))
    }

    @Test("Codable round-trip")
    func codableRoundTrip() throws {
        let timestamp = HLCTimestamp(wallMicros: 123_456_789, counter: 42, peerID: "peer-1")
        let data = try JSONEncoder().encode(timestamp)
        let decoded = try JSONDecoder().decode(HLCTimestamp.self, from: data)
        #expect(decoded == timestamp)
    }
}

import Foundation
