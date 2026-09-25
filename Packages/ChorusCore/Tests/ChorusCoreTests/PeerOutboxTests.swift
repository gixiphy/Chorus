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

/// 逐裝置目錄的佇列分類。
///
/// 兩條規則要守住：目錄整份替換（只留最新）、逐端點回報逐 (端點, 能力) 合併；
/// 而且**兩者之間不可以互相越過**——順序一亂就會有一次變化被接收端丟掉。
@Suite("PeerOutbox 逐裝置目錄")
struct PeerOutboxDirectoryTests {
    private let session = UUID()

    private func directory(_ version: UInt64, endpoints: Int = 1) -> Envelope {
        Envelope(msg: .deviceDirectory(DeviceDirectory(
            peerID: "a",
            sessionID: session,
            version: version,
            endpoints: (0..<endpoints).map {
                RemoteEndpoint(deviceID: "d\($0)", kind: .display, name: "D\($0)", capabilities: [.brightness])
            }
        )))
    }

    private func state(_ deviceID: String, _ value: Double, version: UInt64 = 1) -> Envelope {
        Envelope(msg: .endpointState(EndpointStateUpdate(
            sessionID: session,
            version: version,
            deviceID: deviceID,
            kind: .display,
            capability: .brightness,
            value: value
        )))
    }

    private func drain(_ outbox: inout PeerOutbox) -> [SyncMessage] {
        var messages: [SyncMessage] = []
        while let envelope = outbox.dequeue() { messages.append(envelope.msg) }
        return messages
    }

    @Test("目錄整份替換：佇列裡只留最新一份")
    func directoryReplaces() {
        var outbox = PeerOutbox()
        #expect(outbox.enqueue(directory(1), size: 100) == .queued)
        #expect(outbox.enqueue(directory(2), size: 100) == .merged)
        let messages = drain(&outbox)
        #expect(messages.count == 1)
        guard case let .deviceDirectory(directory) = messages[0] else {
            Issue.record("不是目錄")
            return
        }
        #expect(directory.version == 2)
    }

    @Test("逐端點回報依 (端點, 能力) 合併，不同端點互不影響")
    func endpointStateCoalescesPerEndpoint() {
        var outbox = PeerOutbox()
        #expect(outbox.enqueue(state("d0", 0.1), size: 50) == .queued)
        #expect(outbox.enqueue(state("d1", 0.5), size: 50) == .queued)
        #expect(outbox.enqueue(state("d0", 0.2), size: 50) == .merged)
        let values = drain(&outbox).compactMap { message -> (String, Double)? in
            guard case let .endpointState(update) = message else { return nil }
            return (update.deviceID, update.value)
        }
        #expect(values.count == 2)
        #expect(values.first { $0.0 == "d0" }?.1 == 0.2)
        #expect(values.first { $0.0 == "d1" }?.1 == 0.5)
    }

    @Test("回報不會被合併到更新的目錄前面")
    func stateDoesNotJumpAheadOfDirectory() {
        var outbox = PeerOutbox()
        _ = outbox.enqueue(state("d0", 0.1), size: 50)
        _ = outbox.enqueue(directory(2), size: 100)
        // 合併過去的話，接收端會先套用一筆對照舊版本無效的回報（丟掉），
        // 再被整份替換——那次變化就這樣不見了。
        #expect(outbox.enqueue(state("d0", 0.3), size: 50) == .queued)
        let messages = drain(&outbox)
        #expect(messages.count == 3)
        if case .deviceDirectory = messages[1] {} else { Issue.record("目錄應該在中間") }
    }

    @Test("目錄也不會被合併到更早的回報前面")
    func directoryDoesNotJumpAheadOfState() {
        var outbox = PeerOutbox()
        _ = outbox.enqueue(directory(1), size: 100)
        _ = outbox.enqueue(state("d0", 0.3), size: 50)
        // 反方向同樣會丟掉一次變化：接收端先套用新目錄，後面那筆回報的
        // 版本已經過期，一樣被丟掉。
        #expect(outbox.enqueue(directory(2), size: 100) == .queued)
        let messages = drain(&outbox)
        #expect(messages.count == 3)
        if case .endpointState = messages[1] {} else { Issue.record("回報應該在中間") }
    }

    @Test("指令與結果永遠不合併：每一則都是一次操作或一次回覆")
    func commandsNeverCoalesce() {
        var outbox = PeerOutbox()
        let first = EndpointCommand(deviceID: "d0", kind: .display, capability: .brightness, value: 0.2)
        let second = EndpointCommand(deviceID: "d0", kind: .display, capability: .brightness, value: 0.4)
        #expect(outbox.enqueue(Envelope(msg: .endpointCommand(first)), size: 50) == .queued)
        #expect(outbox.enqueue(Envelope(msg: .endpointCommand(second)), size: 50) == .queued)
        #expect(outbox.enqueue(
            Envelope(msg: .endpointCommandResult(EndpointCommandResult(id: first.id, outcome: .applied, value: 0.2))),
            size: 50
        ) == .queued)
        #expect(drain(&outbox).count == 3)
    }
}
