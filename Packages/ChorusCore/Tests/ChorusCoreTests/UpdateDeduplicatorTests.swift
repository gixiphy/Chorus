import Testing
@testable import ChorusCore

// 注意：#expect 巨集無法直接展開 mutating 呼叫，一律先存變數再斷言。
@Suite("UpdateDeduplicator")
struct UpdateDeduplicatorTests {
    @Test("Fresh entries pass, repeats are duplicates")
    func basicDedup() {
        var dedup = UpdateDeduplicator()
        let first = dedup.isDuplicate(originID: "A", seq: 1)
        let repeated = dedup.isDuplicate(originID: "A", seq: 1)
        let next = dedup.isDuplicate(originID: "A", seq: 2)
        #expect(!first)
        #expect(repeated)
        #expect(!next)
    }

    @Test("Same seq from different origins is independent")
    func perOriginIndependence() {
        var dedup = UpdateDeduplicator()
        let fromA = dedup.isDuplicate(originID: "A", seq: 1)
        let fromB = dedup.isDuplicate(originID: "B", seq: 1)
        #expect(!fromA)
        #expect(!fromB)
    }

    @Test("Capacity eviction forgets oldest entries")
    func capacityEviction() {
        var dedup = UpdateDeduplicator(capacity: 3)
        for seq: UInt64 in 1...4 {
            let duplicate = dedup.isDuplicate(originID: "A", seq: seq)
            #expect(!duplicate)
        }
        // seq 1 已被擠出 LRU → 視為新
        let forgotten = dedup.isDuplicate(originID: "A", seq: 1)
        let stillKnown = dedup.isDuplicate(originID: "A", seq: 4)
        #expect(!forgotten)
        #expect(stillKnown)
    }
}
