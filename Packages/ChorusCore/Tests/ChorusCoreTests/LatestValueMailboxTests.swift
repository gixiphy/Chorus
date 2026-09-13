import Testing
@testable import ChorusCore

@Suite("LatestValueMailbox")
struct LatestValueMailboxTests {
    @Test("Only the first put in a round asks for a drain; later values replace earlier ones")
    func coalesces() {
        var mailbox = LatestValueMailbox<String, Double>()
        let first = mailbox.put(0.1, for: "volume")
        let second = mailbox.put(0.2, for: "volume")
        let other = mailbox.put(0.5, for: "balance")
        let third = mailbox.put(0.3, for: "volume")
        #expect(first)
        #expect(!second)
        #expect(!other)
        #expect(!third)

        let taken = mailbox.take()
        #expect(taken.map(\.key) == ["volume", "balance"])
        #expect(taken.map(\.value) == [0.3, 0.5])
        #expect(mailbox.isEmpty)
    }

    @Test("After a take, the next put schedules again")
    func reschedulesAfterTake() {
        var mailbox = LatestValueMailbox<Int, Int>()
        _ = mailbox.put(1, for: 1)
        _ = mailbox.take()
        let again = mailbox.put(2, for: 1)
        #expect(again)
    }

    @Test("A custom combine keeps flags that must not be lost")
    func combine() {
        var mailbox = LatestValueMailbox<String, (value: Int, oneShot: Bool)>()
        _ = mailbox.put((1, true), for: "input") { pending, new in (new.value, pending.oneShot || new.oneShot) }
        _ = mailbox.put((2, false), for: "input") { pending, new in (new.value, pending.oneShot || new.oneShot) }
        let taken = mailbox.take()
        #expect(taken.count == 1)
        #expect(taken[0].value.value == 2)
        #expect(taken[0].value.oneShot)
    }
}
