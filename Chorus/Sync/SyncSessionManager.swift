import ChorusCore
import Foundation
import Network
import Observation

/// full-mesh 成員管理：探索已配對裝置、建立/接受 TLS-PSK 連線、hello 驗證、
/// 斷線重撥（指數退避）。連線去重規則：peerID 字典序較小者當撥號方。
@MainActor
@Observable
final class SyncSessionManager {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    /// peerID → 連線狀態（UI 顯示用）。
    private(set) var connectionStates: [String: ConnectionState] = [:]

    @ObservationIgnored private let instance: InstanceConfig
    @ObservationIgnored private let pairedPeers: PairedPeersStore
    @ObservationIgnored private let advertiser = BonjourAdvertiser()
    @ObservationIgnored private let browser = BonjourBrowserService()

    @ObservationIgnored private var connections: [String: PeerConnection] = [:]
    @ObservationIgnored private var latestEndpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var dialTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var redialDelay: [String: Double] = [:]

    /// 收到的 envelope 交給上層（M5 的 ControlCoordinator）。ping/pong 在本層處理。
    @ObservationIgnored var envelopeHandler: ((_ peerID: String, _ envelope: Envelope) -> Void)?
    /// 新 session 建立（hello 完成）時通知上層，用於互換 fullState。
    @ObservationIgnored var sessionEstablishedHandler: ((_ peerID: String) -> Void)?

    var localPeerID: String { instance.peerID }

    init(instance: InstanceConfig, pairedPeers: PairedPeersStore) {
        self.instance = instance
        self.pairedPeers = pairedPeers
        for peer in pairedPeers.peers {
            connectionStates[peer.peerID] = .disconnected
        }
    }

    func start() {
        restartAdvertiser()
        browser.start(myPeerID: instance.peerID)
        Task { [weak self] in
            guard let stream = self?.browser.discoveries else { return }
            for await peers in stream {
                self?.handleDiscoveries(peers)
            }
        }
        Task { [weak self] in
            guard let stream = self?.advertiser.inboundConnections else { return }
            for await nwConnection in stream {
                self?.handleInbound(nwConnection)
            }
        }
    }

    /// 配對集合變更後重建 listener 的 PSK 表。
    func restartAdvertiser() {
        let psks = pairedPeers.peers.compactMap { peer -> (identity: String, psk: Data)? in
            pairedPeers.psk(for: peer.peerID).map { (identity: peer.peerID, psk: $0) }
        }
        advertiser.restart(
            peerID: instance.peerID,
            deviceName: instance.deviceDisplayName,
            psks: psks,
            fixedPort: instance.syncListenPort
        )
        for peer in pairedPeers.peers {
            if connectionStates[peer.peerID] == nil {
                connectionStates[peer.peerID] = .disconnected
            }
            maybeDial(peer.peerID)
        }
    }

    /// 廣播 envelope 給所有已連線 peer。
    func broadcast(_ envelope: Envelope) {
        for connection in connections.values {
            Task { try? await connection.send(envelope) }
        }
    }

    /// 送給特定 peer。
    func send(_ envelope: Envelope, to peerID: String) {
        guard let connection = connections[peerID] else { return }
        Task { try? await connection.send(envelope) }
    }

    var connectedPeerIDs: [String] { Array(connections.keys) }

    // MARK: - 探索與撥號

    private func handleDiscoveries(_ peers: [DiscoveredPeer]) {
        // 未配對的也先記 endpoint：配對完成後 restartAdvertiser 會補撥
        for peer in peers {
            latestEndpoints[peer.peerID] = peer.endpoint
            if pairedPeers.isPaired(peer.peerID) {
                maybeDial(peer.peerID)
            }
        }
    }

    private func maybeDial(_ peerID: String) {
        // 去重規則：只有字典序較小的一方主動撥號
        guard instance.peerID < peerID else { return }
        guard connections[peerID] == nil, dialTasks[peerID] == nil else { return }
        guard let endpoint = latestEndpoints[peerID] ?? manualEndpoint(for: peerID),
              let psk = pairedPeers.psk(for: peerID)
        else { return }

        connectionStates[peerID] = .connecting
        dialTasks[peerID] = Task { [weak self, instance] in
            let connection = PeerConnection.dial(
                endpoint: endpoint,
                myPeerID: instance.peerID,
                psk: psk,
                expectedPeerID: peerID,
                onClose: {}
            )
            do {
                try await connection.start()
                self?.beginSession(connection)
            } catch {
                self?.dialFailed(peerID)
            }
            self?.dialTasks[peerID] = nil
        }
    }

    /// 已配對裝置記錄的手動端點（"host:port"）；mDNS 不可用時的 fallback。
    private func manualEndpoint(for peerID: String) -> NWEndpoint? {
        guard let record = pairedPeers.peers.first(where: { $0.peerID == peerID }),
              let manual = record.manualEndpoint
        else { return nil }
        let parts = manual.split(separator: ":")
        guard parts.count == 2,
              let portValue = UInt16(parts[1]),
              let port = NWEndpoint.Port(rawValue: portValue)
        else { return nil }
        return .hostPort(host: NWEndpoint.Host(String(parts[0])), port: port)
    }

    private func dialFailed(_ peerID: String) {
        if connections[peerID] == nil {
            connectionStates[peerID] = .disconnected
        }
        scheduleRedial(peerID)
    }

    private func scheduleRedial(_ peerID: String) {
        guard instance.peerID < peerID else { return }
        let delay = redialDelay[peerID] ?? 1
        redialDelay[peerID] = min(delay * 2, 30)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.maybeDial(peerID)
        }
    }

    // MARK: - Inbound

    private func handleInbound(_ nwConnection: NWConnection) {
        Task { [weak self] in
            let connection = PeerConnection.inbound(connection: nwConnection, onClose: {})
            do {
                try await connection.start()
                self?.beginSession(connection)
            } catch {
                connection.close()
            }
        }
    }

    // MARK: - Session（hello 交換與 envelope 迴圈）

    private func beginSession(_ connection: PeerConnection) {
        Task { [instance] in
            let myHello = Hello(
                peerID: instance.peerID,
                deviceName: instance.deviceDisplayName,
                protocolVersion: ChorusProtocol.version
            )
            try? await connection.send(Envelope(msg: .hello(myHello)))

            var iterator = connection.incoming.makeAsyncIterator()
            guard let first = await iterator.next(), case let .hello(hello) = first.msg else {
                connection.close()
                return
            }
            guard acceptSession(connection, hello: hello) else {
                connection.close()
                return
            }
            while let envelope = await iterator.next() {
                handleEnvelope(peerID: hello.peerID, envelope)
            }
            handleClosed(connection, peerID: hello.peerID)
        }
    }

    /// hello 驗證＋重複連線裁決。回傳 false 表示呼叫端應關閉連線。
    private func acceptSession(_ connection: PeerConnection, hello: Hello) -> Bool {
        let peerID = hello.peerID
        // TLS-PSK 已證明對方持有配對金鑰；這裡是 defense in depth
        guard pairedPeers.isPaired(peerID) else { return false }
        if let expected = connection.expectedPeerID, expected != peerID { return false }
        guard hello.protocolVersion == ChorusProtocol.version else { return false }

        if let existing = connections[peerID] {
            // 兩條連線並存：保留「應然撥號方」（min peerID）建立的那條
            let iAmDialer = instance.peerID < peerID
            let existingPreferred = existing.isDialer == iAmDialer
            if existingPreferred {
                return false // 關掉新的
            }
            existing.close()
        }

        connections[peerID] = connection
        connectionStates[peerID] = .connected
        redialDelay[peerID] = nil
        sessionEstablishedHandler?(peerID)
        return true
    }

    private func handleClosed(_ connection: PeerConnection, peerID: String) {
        // 只清掉「目前登記的那條」；重複連線裁決關掉的舊連線不影響新的
        guard connections[peerID] === connection else { return }
        connections[peerID] = nil
        connectionStates[peerID] = .disconnected
        scheduleRedial(peerID)
    }

    private func handleEnvelope(peerID: String, _ envelope: Envelope) {
        switch envelope.msg {
        case let .ping(token):
            send(Envelope(msg: .pong(token)), to: peerID)
        default:
            envelopeHandler?(peerID, envelope)
        }
    }
}
