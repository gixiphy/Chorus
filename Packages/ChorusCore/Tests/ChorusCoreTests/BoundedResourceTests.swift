import Testing
@testable import ChorusCore

@Suite("BoundedLogBuffer")
struct BoundedLogBufferTests {
    @Test("Normal lines stop at the reserve; errors still get in; drops are counted")
    func reserveForErrors() {
        var buffer = BoundedLogBuffer(limits: .init(maxLines: 10, maxBytes: 10_000, reservedErrorLines: 3))
        for index in 0..<20 {
            buffer.append("info \(index)\n")
        }
        #expect(buffer.lines.count == 7)
        #expect(buffer.droppedCount == 13)
        let result1 = buffer.append("error\n", priority: .error)
        #expect(result1)
        #expect(buffer.lines.count == 8)

        let drained = buffer.drain()
        #expect(drained.lines.count == 8)
        #expect(drained.dropped == 13)
        #expect(buffer.lines.isEmpty)
        #expect(buffer.byteCount == 0)
        #expect(buffer.droppedCount == 0)
    }

    @Test("The byte budget is enforced as well as the line count")
    func byteBudget() {
        var buffer = BoundedLogBuffer(limits: .init(maxLines: 1_000, maxBytes: 100, reservedErrorLines: 0))
        let line = String(repeating: "x", count: 40) + "\n"
        let result2 = buffer.append(line)
        #expect(result2)
        let result3 = buffer.append(line)
        #expect(result3)
        let result4 = buffer.append(line)
        #expect(!result4)
        #expect(buffer.byteCount <= 100)
    }

    @Test("Long lines are truncated on a character boundary")
    func truncation() {
        let line = String(repeating: "錯", count: 100) + "\n"
        let truncated = BoundedLogBuffer.truncate(line, toBytes: 64)
        #expect(truncated.utf8.count <= 64)
        #expect(truncated.hasSuffix(BoundedLogBuffer.truncationMarker))
        #expect(!truncated.contains("\u{FFFD}"))
        #expect(BoundedLogBuffer.truncate("short\n", toBytes: 64) == "short\n")
    }
}

@Suite("AutomationAdmission")
struct AutomationAdmissionTests {
    @Test("Connections and event streams have separate caps")
    func connectionCaps() {
        var admission = AutomationAdmission(limits: .init(maxConnections: 2, maxEventStreams: 1))
        let result5 = admission.admitConnection()
        #expect(result5)
        let result6 = admission.admitConnection()
        #expect(result6)
        let result7 = admission.admitConnection()
        #expect(!result7)
        let result8 = admission.admitEventStream()
        #expect(result8)
        let result9 = admission.admitEventStream()
        #expect(!result9)
        admission.releaseConnection()
        admission.releaseEventStream()
        let result10 = admission.admitConnection()
        #expect(result10)
        let result11 = admission.admitEventStream()
        #expect(result11)
    }

    @Test("Batches over the limit are rejected; pending commands stay reserved until released")
    func commandBudget() {
        var admission = AutomationAdmission(limits: .init(maxBatch: 4, maxPendingCommands: 6))
        let result12 = admission.admitCommands(5)
        #expect(result12 == .batchTooLarge(limit: 4))
        let result13 = admission.admitCommands(4)
        #expect(result13 == nil)
        let result14 = admission.admitCommands(3)
        #expect(result14 == .overloaded)
        let result15 = admission.admitCommands(2)
        #expect(result15 == nil)
        admission.releaseCommands(4)
        #expect(admission.pendingCommands == 2)
        let result16 = admission.admitCommands(4)
        #expect(result16 == nil)
    }

    @Test("Releasing never goes negative")
    func releaseFloor() {
        var admission = AutomationAdmission()
        admission.releaseConnection()
        admission.releaseEventStream()
        admission.releaseCommands(10)
        #expect(admission.connections == 0)
        #expect(admission.eventStreams == 0)
        #expect(admission.pendingCommands == 0)
    }
}

@Suite("EventStreamBacklog")
struct EventStreamBacklogTests {
    @Test("A slow reader hits the event or byte limit")
    func limits() {
        var backlog = EventStreamBacklog(maxEvents: 2, maxBytes: 100)
        let result17 = backlog.reserve(bytes: 40)
        #expect(result17)
        let result18 = backlog.reserve(bytes: 40)
        #expect(result18)
        let result19 = backlog.reserve(bytes: 1)
        #expect(!result19)
        backlog.complete(bytes: 40)
        let result20 = backlog.reserve(bytes: 70)
        #expect(!result20)
        let result21 = backlog.reserve(bytes: 60)
        #expect(result21)
    }
}
