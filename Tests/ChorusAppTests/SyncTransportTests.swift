import Foundation
import Network
import Synchronization
import Testing
@testable import Chorus

/// Batch C：framed 連線的收尾與送出期限。走真的 loopback TCP，不經 TLS 與 Bonjour。
@Suite("同步傳輸：收尾與期限", .serialized)
struct SyncTransportTests {
    private final class ConnectionBag: @unchecked Sendable {
        private let connections = Mutex<[NWConnection]>([])
        func append(_ connection: NWConnection) { connections.withLock { $0.append(connection) } }
        func cancelAll() { connections.withLock { $0.forEach { $0.cancel() } } }
        var first: NWConnection? { connections.withLock { $0.first } }
    }

    /// 只接受連線、完全不讀的對端。
    private final class SilentListener: @unchecked Sendable {
        let listener: NWListener
        private let queue = DispatchQueue(label: "test.silent-listener")
        private let accepted = ConnectionBag()

        init() throws {
            let parameters = NWParameters.tcp
            parameters.requiredInterfaceType = .loopback
            listener = try NWListener(using: parameters, on: .any)
            listener.newConnectionHandler = { [accepted, queue] connection in
                connection.start(queue: queue)
                accepted.append(connection)
            }
        }

        func start() async throws -> NWEndpoint.Port {
            listener.start(queue: queue)
            for _ in 0..<200 {
                if let port = listener.port, port.rawValue != 0 { return port }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw FramedConnectionError.closed
        }

        func cancelAccepted() {
            accepted.cancelAll()
        }

        func waitForAccepted() async throws -> NWConnection {
            for _ in 0..<200 {
                if let connection = accepted.first { return connection }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw FramedConnectionError.closed
        }

        deinit {
            cancelAccepted()
            listener.cancel()
        }
    }

    private final class Counter: Sendable {
        private let value = Mutex(0)
        func increment() { value.withLock { $0 += 1 } }
        var count: Int { value.withLock { $0 } }
    }

    private func connect(
        to port: NWEndpoint.Port,
        receiveLimits: FramedNWConnection.ReceiveLimits? = nil,
        onClose: @escaping @Sendable () -> Void = {}
    ) async throws -> FramedNWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        let framed = FramedNWConnection(
            connection: connection, label: "test", receiveLimits: receiveLimits, onClose: onClose
        )
        try await framed.start(timeout: .seconds(5))
        return framed
    }

    @Test("close 與對端斷線同時發生：onClose 只觸發一次，stream 結束")
    func closeIsExactlyOnce() async throws {
        let listener = try SilentListener()
        let port = try await listener.start()
        let closes = Counter()
        let framed = try await connect(to: port) { closes.increment() }

        listener.cancelAccepted()
        framed.close()
        framed.close()
        try await Task.sleep(for: .milliseconds(200))

        #expect(closes.count == 1)
        #expect(framed.isClosed)
        var iterator = framed.incoming.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test("關閉之後送出立刻失敗")
    func sendAfterClose() async throws {
        let listener = try SilentListener()
        let port = try await listener.start()
        let framed = try await connect(to: port)
        framed.close()
        await #expect(throws: FramedConnectionError.closed) {
            try await framed.send(Data([1, 2, 3]))
        }
    }

    @Test("超過單一 frame 上限的 payload 不送")
    func oversizedPayload() async throws {
        let listener = try SilentListener()
        let port = try await listener.start()
        let framed = try await connect(to: port)
        defer { framed.close() }
        await #expect(throws: FramedConnectionError.payloadTooLarge) {
            try await framed.send(Data(count: FramedNWConnection.maxFrameLength + 1))
        }
    }

    @Test("對端不讀、緩衝塞滿：送出在期限內失敗並關閉連線")
    func sendTimesOutWhenPeerStopsReading() async throws {
        let listener = try SilentListener()
        let port = try await listener.start()
        let closes = Counter()
        let framed = try await connect(to: port) { closes.increment() }
        defer { framed.close() }

        let chunk = Data(count: FramedNWConnection.maxFrameLength)
        var timedOut = false
        var sent = 0
        let started = ContinuousClock.now
        while sent < 256, ContinuousClock.now - started < .seconds(30) {
            do {
                try await framed.send(chunk, timeout: .milliseconds(300))
                sent += 1
            } catch FramedConnectionError.sendTimedOut {
                timedOut = true
                break
            }
        }
        #expect(timedOut, "送了 \(sent) MiB 仍未逾時")
        #expect(framed.isClosed)
        try await Task.sleep(for: .milliseconds(100))
        #expect(closes.count == 1)
    }

    @Test("接收背壓：上層沒處理完就暫停讀取，處理完才繼續")
    func receivePausesUntilAcknowledged() async throws {
        let listener = try SilentListener()
        let port = try await listener.start()
        let framed = try await connect(to: port, receiveLimits: .init(frames: 4, bytes: 1 << 20))
        defer { framed.close() }
        let server = try await listener.waitForAccepted()

        for index in 0..<20 {
            var frame = Data()
            var length = UInt32(1).bigEndian
            withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
            frame.append(UInt8(index))
            server.send(content: frame, completion: .contentProcessed { _ in })
        }

        let counter = Counter()
        let reader = Task {
            for await _ in framed.incoming {
                counter.increment()
            }
        }
        defer { reader.cancel() }
        try await Task.sleep(for: .milliseconds(500))
        #expect(counter.count == 4)

        for _ in 0..<4 {
            framed.acknowledge(bytes: 1)
        }
        try await Task.sleep(for: .milliseconds(500))
        #expect(counter.count == 8)
    }
}
