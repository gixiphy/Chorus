import Foundation
import Synchronization

/// 測試用的成對記憶體 transport：一端 send、另一端 incoming 收到。
/// 經過 Envelope 編解碼 round-trip，順便驗證線上格式。
public final class InMemoryTransport: PeerTransport {
    public let incoming: AsyncStream<Envelope>
    private let incomingContinuation: AsyncStream<Envelope>.Continuation

    private struct Link {
        var peerContinuation: AsyncStream<Envelope>.Continuation?
        var closed = false
    }

    private let link = Mutex(Link())

    private init() {
        var continuation: AsyncStream<Envelope>.Continuation!
        incoming = AsyncStream { continuation = $0 }
        incomingContinuation = continuation
    }

    /// 建立互相連接的一對 transport。
    public static func pair() -> (InMemoryTransport, InMemoryTransport) {
        let a = InMemoryTransport()
        let b = InMemoryTransport()
        a.link.withLock { $0.peerContinuation = b.incomingContinuation }
        b.link.withLock { $0.peerContinuation = a.incomingContinuation }
        return (a, b)
    }

    public func send(_ envelope: Envelope) async throws {
        let continuation = try link.withLock { state -> AsyncStream<Envelope>.Continuation in
            guard !state.closed, let peer = state.peerContinuation else {
                throw PeerTransportError.closed
            }
            return peer
        }
        // 走一次真實編解碼，確保訊息可序列化
        let data = try EnvelopeCoding.encode(envelope)
        guard case let .success(decoded) = EnvelopeCoding.decode(data) else {
            throw PeerTransportError.closed
        }
        continuation.yield(decoded)
    }

    public func close() {
        let peer = link.withLock { state -> AsyncStream<Envelope>.Continuation? in
            guard !state.closed else { return nil }
            state.closed = true
            let continuation = state.peerContinuation
            state.peerContinuation = nil
            return continuation
        }
        peer?.finish()
        incomingContinuation.finish()
    }
}
