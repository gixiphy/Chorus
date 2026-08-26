import ChorusCore
import Foundation
import Network

/// 一條已認證（TLS-PSK）連線上的 Envelope 通道，實作 ChorusCore 的 PeerTransport。
final class PeerConnection: PeerTransport, @unchecked Sendable {
    let incoming: AsyncStream<Envelope>
    private let incomingContinuation: AsyncStream<Envelope>.Continuation
    private let framed: FramedNWConnection
    private let pumpTask: Task<Void, Never>

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

        let stream = framed.incoming
        let localContinuation = incomingContinuation
        pumpTask = Task {
            for await frame in stream {
                switch EnvelopeCoding.decode(frame) {
                case let .success(envelope):
                    localContinuation.yield(envelope)
                case .failure(.unsupportedVersion):
                    continue // 較新版本的訊息：忽略，維持連線
                case .failure(.malformed):
                    continue // 單筆壞資料：丟棄（framing 已保證邊界）
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
        let framed = FramedNWConnection(connection: connection, label: "dial-\(expectedPeerID.prefix(8))", onClose: onClose)
        return PeerConnection(framed: framed, expectedPeerID: expectedPeerID, isDialer: true)
    }

    /// listener 收到的連線（TLS 已在 listener 參數層完成 PSK 驗證）。
    static func inbound(
        connection: NWConnection,
        onClose: @escaping @Sendable () -> Void
    ) -> PeerConnection {
        let framed = FramedNWConnection(connection: connection, label: "inbound", onClose: onClose)
        return PeerConnection(framed: framed, expectedPeerID: nil, isDialer: false)
    }

    func start() async throws {
        try await framed.start()
    }

    func send(_ envelope: Envelope) async throws {
        let data = try EnvelopeCoding.encode(envelope)
        try await framed.send(data)
    }

    func close() {
        pumpTask.cancel()
        framed.close()
    }
}
