import ChorusCore
import Foundation
import Network
import Synchronization

/// 一條已認證（TLS-PSK）連線上的 Envelope 通道，實作 ChorusCore 的 PeerTransport。
///
/// 收發都有上限：送出走 `PeerOutbox`（可取代的狀態合併、同時只送一則、放不下就
/// 斷線重新同步）；接收端上層每處理完一則呼叫 `markConsumed`，還沒處理的積壓到
/// 上限就暫停讀取（`FramedNWConnection.ReceiveLimits`）。
final class PeerConnection: PeerTransport, @unchecked Sendable {
    static let outboxLimits = PeerOutbox.Limits(maxItems: 64, maxBytes: 2 << 20)
    static let receiveLimits = FramedNWConnection.ReceiveLimits(frames: 64, bytes: 2 << 20)

    let incoming: AsyncStream<Envelope>
    private let incomingContinuation: AsyncStream<Envelope>.Continuation
    private let framed: FramedNWConnection
    private let pumpTask: Task<Void, Never>
    private let received: ReceivedSizes

    private struct OutboxState {
        var outbox = PeerOutbox(limits: PeerConnection.outboxLimits)
        var sending = false
        var closed = false
    }

    private let outbox = Mutex(OutboxState())
    private static let log = ChorusLog(category: "sync")

    /// 撥號方在 start 前就知道對方是誰；listener 端 hello 之後才知道。
    let expectedPeerID: String?
    /// 這條連線是我方主動撥出的（重複連線裁決用）。
    let isDialer: Bool

    private init(framed: FramedNWConnection, expectedPeerID: String?, isDialer: Bool) {
        self.framed = framed
        self.expectedPeerID = expectedPeerID
        self.isDialer = isDialer
        var continuation: AsyncStream<Envelope>.Continuation!
        incoming = AsyncStream { continuation = $0 }
        incomingContinuation = continuation
        let received = ReceivedSizes()
        self.received = received

        let stream = framed.incoming
        let localContinuation = incomingContinuation
        pumpTask = Task {
            for await frame in stream {
                switch EnvelopeCoding.decode(frame) {
                case let .success(envelope):
                    received.push(frame.count)
                    localContinuation.yield(envelope)
                case .failure(.unsupportedVersion), .failure(.malformed):
                    // 較新版本的訊息或單筆壞資料：丟棄、維持連線，額度立刻還回去
                    framed.acknowledge(bytes: frame.count)
                }
            }
            localContinuation.finish()
        }
    }

    /// 撥號建立連線（identity hint = 我方 peerID，讓 listener 選對 PSK）。
    static func dial(
        endpoint: NWEndpoint,
        myPeerID: String,
        psk: Data,
        expectedPeerID: String,
        onClose: @escaping @Sendable () -> Void
    ) -> PeerConnection {
        let params = ChorusTLS.parameters(psks: [(identity: myPeerID, psk: psk)])
        let connection = NWConnection(to: endpoint, using: params)
        let framed = FramedNWConnection(
            connection: connection, label: "dial-\(expectedPeerID.prefix(8))",
            receiveLimits: receiveLimits, onClose: onClose
        )
        return PeerConnection(framed: framed, expectedPeerID: expectedPeerID, isDialer: true)
    }

    /// listener 收到的連線（TLS 已在 listener 參數層完成 PSK 驗證）。
    static func inbound(
        connection: NWConnection,
        onClose: @escaping @Sendable () -> Void
    ) -> PeerConnection {
        let framed = FramedNWConnection(
            connection: connection, label: "inbound", receiveLimits: receiveLimits, onClose: onClose
        )
        return PeerConnection(framed: framed, expectedPeerID: nil, isDialer: false)
    }

    func start() async throws {
        try await framed.start()
    }

    /// 直接送出並等網路層收下（hello 用）。session 建立後的訊息走 `enqueue`。
    func send(_ envelope: Envelope) async throws {
        let data = try EnvelopeCoding.encode(envelope)
        // sync.send 的在途數就是「送出去還沒被網路層收下」的積壓
        let framed = framed
        try await OperationMetrics.shared.measureAsync("sync.send") {
            do {
                try await FaultRegistry.shared.inject(
                    .syncSend, limit: FramedNWConnection.sendTimeout, abandonIf: { framed.isClosed }
                )
            } catch is FaultRegistry.LimitReached {
                // 與真的送不出去同一個結果：期限到、連線關掉
                framed.close()
                throw FramedConnectionError.sendTimedOut
            }
            try await framed.send(data)
        }
    }

    /// 排進送往對方的佇列（fire-and-forget）。放不下就斷線——重連時互換的 fullState
    /// 會補回狀態，比默默丟掉一則指令安全。
    func enqueue(_ envelope: Envelope) {
        guard let size = try? EnvelopeCoding.encode(envelope).count else { return }
        let outcome = outbox.withLock { state -> (result: PeerOutbox.EnqueueResult, startSending: Bool)? in
            guard !state.closed else { return nil }
            let result = state.outbox.enqueue(envelope, size: size)
            guard result != .overflow, !state.sending else { return (result, false) }
            state.sending = true
            return (result, true)
        }
        guard let outcome else { return }
        switch outcome.result {
        case .queued:
            OperationMetrics.shared.adjustGauge("sync.outbox", by: 1)
        case .merged:
            break
        case .overflow:
            Self.log.error("送往 \(expectedPeerID?.prefix(8) ?? "peer") 的佇列已滿，斷線重新同步")
            close()
            return
        }
        if outcome.startSending {
            Task { await self.drainOutbox() }
        }
    }

    /// 收訊迴圈處理完一則 envelope 後呼叫：釋放接收額度，暫停中的讀取才會繼續。
    func markConsumed() {
        guard let size = received.pop() else { return }
        framed.acknowledge(bytes: size)
    }

    func close() {
        let dropped = outbox.withLock { state -> Int in
            guard !state.closed else { return 0 }
            state.closed = true
            let remaining = state.outbox.count
            state.outbox = PeerOutbox(limits: Self.outboxLimits)
            return remaining
        }
        if dropped > 0 {
            OperationMetrics.shared.adjustGauge("sync.outbox", by: -dropped)
        }
        pumpTask.cancel()
        framed.close()
    }

    /// 一次送一則，送完再拿下一則；佇列空了或連線關了就停。
    private func drainOutbox() async {
        while true {
            let next = outbox.withLock { state -> Envelope? in
                guard !state.closed, let envelope = state.outbox.dequeue() else {
                    state.sending = false
                    return nil
                }
                return envelope
            }
            guard let next else { return }
            OperationMetrics.shared.adjustGauge("sync.outbox", by: -1)
            do {
                try await send(next)
            } catch {
                close()
                return
            }
        }
    }
}

/// 已交給上層、還沒處理完的 frame 大小（先進先出）。
private final class ReceivedSizes: Sendable {
    private let sizes = Mutex<[Int]>([])

    func push(_ size: Int) {
        sizes.withLock { $0.append(size) }
    }

    func pop() -> Int? {
        sizes.withLock { $0.isEmpty ? nil : $0.removeFirst() }
    }
}
