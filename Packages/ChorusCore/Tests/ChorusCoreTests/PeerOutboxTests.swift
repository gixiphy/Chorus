import Foundation
import Testing
@testable import ChorusCore

@Suite("PeerOutbox")
struct PeerOutboxTests {
    private let hlc = HLCTimestamp(wallMicros: 1, counter: 0, peerID: "a")
    private let brightness = ControlKey.brightness(displayUUID: nil)
    private let volume = ControlKey.volume(deviceUID: nil)

    private func update(_ key: ControlKey, _ value: Double, seq: UInt64 = 1) -> Envelope {
        Envelope(msg: .stateUpdate(StateUpdate(originID: "a", seq: seq, hlc: hlc, key: key, value: value)))
    }

    private func drain(_ outbox: inout PeerOutbox) -> [SyncMessage] {
        var messages: [SyncMessage] = []
        while let envelope = outbox.dequeue() {
            messages.append(envelope.msg)
        }
        return messages
    }

    private func values(_ messages: [SyncMessage]) -> [Double] {
        messages.compactMap {
            if case let .stateUpdate(update) = $0 { return update.value }
            return nil
        }
    }

    @Test("Slider intermediates for the same key collapse to the newest value")
    func coalescesSameKey() {
        var outbox = PeerOutbox()
        let result1 = outbox.enqueue(update(brightness, 0.1, seq: 1), size: 100)
        #expect(result1 == .queued)
        let result2 = outbox.enqueue(update(volume, 0.5, seq: 2), size: 100)
        #expect(result2 == .queued)
        let result3 = outbox.enqueue(update(brightness, 0.2, seq: 3), size: 100)
        #expect(result3 == .merged)
        let result4 = outbox.enqueue(update(brightness, 0.3, seq: 4), size: 100)
        #expect(result4 == .merged)
        #expect(outbox.count == 2)
        #expect(values(drain(&outbox)) == [0.3, 0.5])
    }

    @Test("A command is an ordering barrier: updates before and after it stay separate")
    func commandIsBarrier() {
        var outbox = PeerOutbox()
        _ = outbox.enqueue(update(brightness, 0.1), size: 100)
        _ = outbox.enqueue(Envelope(msg: .command(Command(key: brightness, value: 0.9))), size: 100)
        let result5 = outbox.enqueue(update(brightness, 0.2), size: 100)
        #expect(result5 == .queued)
        let messages = drain(&outbox)
        #expect(messages.count == 3)
        guard case .command = messages[1] else {
            Issue.record("順序被打亂：\(messages)")
            return
        }
        #expect(values(messages) == [0.1, 0.2])
    }

    @Test("Commands and full state are never merged")
    func nonReplaceableKept() {
        var outbox = PeerOutbox()
        for value in [0.1, 0.2, 0.3] {
            #expect(outbox.enqueue(Envelope(msg: .command(Command(key: brightness, value: value))), size: 50) == .queued)
        }
        #expect(outbox.count == 3)
    }

    @Test("State reports merge entry by entry, newest value wins")
    func reportsMergeByKey() throws {
        var outbox = PeerOutbox()
        let first = StateReport(entries: [.init(key: brightness, value: 0.1), .init(key: volume, value: 0.4)])
        let second = StateReport(entries: [.init(key: brightness, value: 0.7)])
        _ = outbox.enqueue(Envelope(msg: .stateReport(first)), size: 80)
        let result6 = outbox.enqueue(Envelope(msg: .stateReport(second)), size: 40)
        #expect(result6 == .merged)
        let message = try #require(outbox.dequeue()?.msg)
        guard case let .stateReport(merged) = message else {
            Issue.record("應是 stateReport")
            return
        }
        #expect(merged.entries == [.init(key: brightness, value: 0.7), .init(key: volume, value: 0.4)])
    }

    @Test("Heartbeats collapse; the item and byte caps overflow instead of growing")
    func limits() {
        var outbox = PeerOutbox(limits: .init(maxItems: 3, maxBytes: 250))
        let result7 = outbox.enqueue(Envelope(msg: .ping(0)), size: 10)
        #expect(result7 == .queued)
        let result8 = outbox.enqueue(Envelope(msg: .ping(0)), size: 10)
        #expect(result8 == .merged)
        #expect(outbox.enqueue(Envelope(msg: .command(Command(key: volume, value: 1))), size: 100) == .queued)
        #expect(outbox.enqueue(Envelope(msg: .command(Command(key: volume, value: 0))), size: 200) == .overflow)
        #expect(outbox.enqueue(Envelope(msg: .command(Command(key: volume, value: 0))), size: 100) == .queued)
        #expect(outbox.enqueue(Envelope(msg: .stateQuery(StateQuery())), size: 1) == .overflow)
        #expect(outbox.byteCount == 210)
        _ = outbox.dequeue()
        #expect(outbox.byteCount == 200)
    }
}
