import ChorusCore
import Foundation
import Network

/// 廣播 `_chorus._tcp` 服務並接受 TLS-PSK 連線。
/// TXT record 只放 protocol version 與 peerID（探索去重用），不放敏感資訊。
final class BonjourAdvertiser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.hermes.Chorus.listener")
    private var listener: NWListener?

    let inboundConnections: AsyncStream<NWConnection>
    private let inboundContinuation: AsyncStream<NWConnection>.Continuation

    init() {
        var continuation: AsyncStream<NWConnection>.Continuation!
        inboundConnections = AsyncStream { continuation = $0 }
        inboundContinuation = continuation
    }

    /// 以目前的已配對 PSK 集合（重新）啟動 listener。配對集合變更後需再呼叫一次。
    /// `fixedPort` 指定時繫結固定 port（手動端點情境）。
    func restart(
        peerID: String,
        deviceName: String,
        psks: [(identity: String, psk: Data)],
        fixedPort: UInt16? = nil,
        deviceKind: String = "mac",
        capabilities: [String] = []
    ) {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
            // 沒有任何已配對裝置時不開放同步埠（配對走獨立通道）
            guard !psks.isEmpty else { return }
            do {
                let params = ChorusTLS.parameters(psks: psks)
                let newListener: NWListener
                if let fixedPort, let port = NWEndpoint.Port(rawValue: fixedPort) {
                    newListener = try NWListener(using: params, on: port)
                } else {
                    newListener = try NWListener(using: params)
                }
                // 固定 port（手動端點）模式下不註冊 Bonjour：
                // mDNS 被擋（如區域網路權限異常）時註冊失敗會拖垮整個 listener
                if fixedPort == nil {
                    var txt = NWTXTRecord()
                    txt["v"] = "\(ChorusProtocol.version)"
                    txt["pid"] = peerID
                    txt["name"] = deviceName
                    txt["kind"] = deviceKind
                    if !capabilities.isEmpty {
                        txt["caps"] = capabilities.joined(separator: ",")
                    }
                    newListener.service = NWListener.Service(
                        name: "\(deviceName)-\(peerID.prefix(8))",
                        type: ChorusProtocol.serviceType,
                        txtRecord: txt
                    )
                }
                newListener.newConnectionHandler = { [weak self] connection in
                    self?.inboundContinuation.yield(connection)
                }
                newListener.stateUpdateHandler = { _ in }
                newListener.start(queue: queue)
                listener = newListener
            } catch {
                // listener 建立失敗：保持 app 存活（FB16131937 —— 立即退出會吃掉權限提示）
            }
        }
    }

    func stop() {
        queue.async { [self] in
            listener?.cancel()
            listener = nil
        }
    }
}
