import ChorusCore
import CryptoKit
import Foundation
import Network
import Observation

/// 配對流程狀態機。
///
/// 配對走獨立的明文通道（`_chorus-pair._tcp`），只在配對視窗開啟期間存在。
/// 流程：發起方 request（帶 Curve25519 公鑰）→ 接受方使用者按接受 → response →
/// 雙方導出 SAS（6 位數）與 32-byte PSK → 兩邊使用者各自確認 SAS 相符 →
/// 雙 confirm 後存入 Keychain、重建同步 listener。
@MainActor
@Observable
final class PairingController {
    enum Phase: Equatable {
        case idle
        case browsing
        case awaitingResponse(peerName: String)
        case incomingRequest(peerName: String)
        case showingSAS(code: String, peerName: String, localConfirmed: Bool, remoteConfirmed: Bool)
        case completed(peerName: String)
        case failed(String)
    }

    struct Candidate: Identifiable, Equatable {
        let peerID: String
        let name: String
        var id: String { peerID }
    }

    static let pairingServiceType = "_chorus-pair._tcp"

    private(set) var phase: Phase = .idle
    private(set) var candidates: [Candidate] = []
    /// 診斷用：pairing listener / browser 的最近狀態。
    private(set) var listenerState = "not-started"
    private(set) var browserState = "not-started"

    @ObservationIgnored private let instance: InstanceConfig
    @ObservationIgnored private let pairedPeers: PairedPeersStore
    @ObservationIgnored private weak var sessionManager: SyncSessionManager?
    /// 本機能力（PairHello 用；AppState 組裝時設定）。
    @ObservationIgnored var localCapabilities: [String] = ["display", "audio"]

    @ObservationIgnored private let listenerQueue = DispatchQueue(label: "com.hermes.Chorus.pairing")
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let browser = BonjourBrowserService()
    @ObservationIgnored private var browseTask: Task<Void, Never>?
    @ObservationIgnored private var endpoints: [String: NWEndpoint] = [:]

    @ObservationIgnored private var channel: FramedNWConnection?
    @ObservationIgnored private var privateKey: Curve25519.KeyAgreement.PrivateKey?
    @ObservationIgnored private var remoteHello: PairHello?
    @ObservationIgnored private var secrets: PairingCrypto.SessionSecrets?
    @ObservationIgnored private var localConfirmed = false
    @ObservationIgnored private var remoteConfirmed = false

    init(instance: InstanceConfig, pairedPeers: PairedPeersStore, sessionManager: SyncSessionManager) {
        self.instance = instance
        self.pairedPeers = pairedPeers
        self.sessionManager = sessionManager
    }

    // MARK: - 生命週期

    /// 配對視窗開啟：開始廣播與瀏覽。
    func begin() {
        guard phase == .idle else { return }
        phase = .browsing
        startListener()
        browser.start(myPeerID: instance.peerID, serviceType: Self.pairingServiceType)
        browseTask = Task { [weak self] in
            guard let stream = self?.browser.discoveries else { return }
            for await peers in stream {
                self?.updateCandidates(peers)
            }
        }
        Task { [weak self] in
            guard let stream = self?.browser.states else { return }
            for await state in stream {
                self?.browserState = state
            }
        }
    }

    /// 配對視窗關閉：全部收掉。
    func end() {
        listenerQueue.async { [listener] in listener?.cancel() }
        listener = nil
        browser.stop()
        browseTask?.cancel()
        browseTask = nil
        resetSession(sendAbort: phase.isMidPairing)
        candidates = []
        endpoints = [:]
        phase = .idle
    }

    // MARK: - 使用者動作

    /// 發起配對（A 端）。
    func requestPair(with candidate: Candidate) {
        guard case .browsing = phase, let endpoint = endpoints[candidate.peerID] else { return }
        dialForPairing(endpoint: endpoint, peerName: candidate.name)
    }

    /// 手動端點配對（mDNS 不可用時；同機測試走 loopback）。
    func requestPair(host: String, port: UInt16) {
        guard case .browsing = phase, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        dialForPairing(
            endpoint: .hostPort(host: NWEndpoint.Host(host), port: nwPort),
            peerName: "\(host):\(port)"
        )
    }

    private func dialForPairing(endpoint: NWEndpoint, peerName: String) {
        let key = PairingCrypto.makePrivateKey()
        privateKey = key
        phase = .awaitingResponse(peerName: peerName)

        let connection = NWConnection(to: endpoint, using: ChorusTLS.plaintextParameters())
        let framed = FramedNWConnection(connection: connection, label: "pair-dial")
        channel = framed
        Task { [weak self, instance] in
            do {
                try await framed.start()
                let hello = PairHello(
                    peerID: instance.peerID,
                    deviceName: instance.deviceDisplayName,
                    publicKey: key.publicKey.rawRepresentation,
                    protocolVersion: ChorusProtocol.version,
                    syncPort: instance.syncListenPort.map(Int.init),
                    deviceKind: "mac",
                    capabilities: self?.localCapabilities
                )
                try await framed.send(PairingMessageCoding.encode(.request(hello)))
                self?.consume(framed)
            } catch {
                self?.fail("無法連線到對方")
            }
        }
    }

    /// 接受來自對方的配對請求（B 端）。
    func acceptIncoming() {
        guard case .incomingRequest = phase,
              let channel,
              let remoteHello
        else { return }
        let key = PairingCrypto.makePrivateKey()
        privateKey = key
        Task { [weak self, instance] in
            do {
                let hello = PairHello(
                    peerID: instance.peerID,
                    deviceName: instance.deviceDisplayName,
                    publicKey: key.publicKey.rawRepresentation,
                    protocolVersion: ChorusProtocol.version,
                    syncPort: instance.syncListenPort.map(Int.init),
                    deviceKind: "mac",
                    capabilities: self?.localCapabilities
                )
                try await channel.send(PairingMessageCoding.encode(.response(hello)))
                self?.deriveAndShowSAS(remotePublicKey: remoteHello.publicKey)
            } catch {
                self?.fail("回覆失敗")
            }
        }
    }

    func declineIncoming() {
        sendAbortAndReset()
        phase = .browsing
    }

    /// 使用者確認畫面上的 SAS 與對方相符。
    func confirmSAS() {
        guard case let .showingSAS(code, peerName, _, _) = phase else { return }
        localConfirmed = true
        phase = .showingSAS(code: code, peerName: peerName, localConfirmed: true, remoteConfirmed: remoteConfirmed)
        // 必須等 confirm 送達後才 finalize：finalize 會關閉通道，
        // fire-and-forget 會讓關閉搶在送出前，對方永遠收不到 confirm
        Task { [weak self, channel] in
            if let channel {
                try? await channel.send(PairingMessageCoding.encode(.confirm))
            }
            self?.finalizeIfBothConfirmed()
        }
    }

    func cancelPairing() {
        sendAbortAndReset()
        phase = .browsing
    }

    // MARK: - Listener（接受方）

    private func startListener() {
        do {
            let newListener: NWListener
            if let fixedPort = instance.pairListenPort, let port = NWEndpoint.Port(rawValue: fixedPort) {
                // 固定 port（手動端點）模式：不註冊 Bonjour，避免 mDNS 失敗拖垮 listener
                newListener = try NWListener(using: ChorusTLS.plaintextParameters(), on: port)
            } else {
                newListener = try NWListener(using: ChorusTLS.plaintextParameters())
                var txt = NWTXTRecord()
                txt["v"] = "\(ChorusProtocol.version)"
                txt["pid"] = instance.peerID
                txt["name"] = instance.deviceDisplayName
                newListener.service = NWListener.Service(
                    name: "\(instance.deviceDisplayName)-pair",
                    type: Self.pairingServiceType,
                    txtRecord: txt
                )
            }
            newListener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    self?.handleInbound(connection)
                }
            }
            newListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    self?.listenerState = "\(state)"
                }
            }
            newListener.start(queue: listenerQueue)
            listener = newListener
        } catch {
            listenerState = "init-failed: \(error)"
        }
    }

    private func handleInbound(_ connection: NWConnection) {
        guard channel == nil else {
            connection.cancel()
            return
        }
        let framed = FramedNWConnection(connection: connection, label: "pair-inbound")
        channel = framed
        Task { [weak self] in
            do {
                try await framed.start()
                self?.consume(framed)
            } catch {
                self?.resetSession(sendAbort: false)
            }
        }
    }

    // MARK: - 訊息處理

    private func consume(_ framed: FramedNWConnection) {
        Task { [weak self] in
            for await frame in framed.incoming {
                guard let message = PairingMessageCoding.decode(frame) else { continue }
                self?.handle(message)
            }
            // 通道關閉：若還在流程中視為失敗
            if let self, self.phase.isMidPairing {
                self.fail("連線中斷")
            }
        }
    }

    private func handle(_ message: PairingMessage) {
        switch message {
        case let .request(hello):
            guard case .browsing = phase else {
                sendAbortAndReset()
                return
            }
            remoteHello = hello
            phase = .incomingRequest(peerName: hello.deviceName)

        case let .response(hello):
            guard case .awaitingResponse = phase else { return }
            remoteHello = hello
            deriveAndShowSAS(remotePublicKey: hello.publicKey)

        case .confirm:
            remoteConfirmed = true
            if case let .showingSAS(code, peerName, local, _) = phase {
                phase = .showingSAS(code: code, peerName: peerName, localConfirmed: local, remoteConfirmed: true)
            }
            finalizeIfBothConfirmed()

        case .abort:
            resetSession(sendAbort: false)
            phase = .browsing
        }
    }

    private func deriveAndShowSAS(remotePublicKey: Data) {
        guard let privateKey, let remoteHello else { return }
        do {
            let derived = try PairingCrypto.deriveSecrets(privateKey: privateKey, remotePublicKey: remotePublicKey)
            secrets = derived
            phase = .showingSAS(
                code: derived.sasCode,
                peerName: remoteHello.deviceName,
                localConfirmed: false,
                remoteConfirmed: remoteConfirmed
            )
        } catch {
            fail("金鑰交換失敗")
        }
    }

    private func finalizeIfBothConfirmed() {
        guard localConfirmed, remoteConfirmed,
              let secrets, let remoteHello
        else { return }
        // 對方有固定 sync port 時記下手動端點，作為 mDNS 之外的連線 fallback
        let manualEndpoint = remoteHello.syncPort.map { port in
            "\(channel?.remoteHostString ?? "127.0.0.1"):\(port)"
        }
        pairedPeers.add(
            PairedPeer(
                peerID: remoteHello.peerID,
                deviceName: remoteHello.deviceName,
                pairedAt: Date(),
                manualEndpoint: manualEndpoint,
                deviceKind: remoteHello.deviceKind,
                capabilities: remoteHello.capabilities
            ),
            psk: secrets.psk
        )
        sessionManager?.restartAdvertiser()
        let name = remoteHello.deviceName
        resetSession(sendAbort: false)
        phase = .completed(peerName: name)
    }

    // MARK: - 內部

    private func updateCandidates(_ peers: [DiscoveredPeer]) {
        endpoints = Dictionary(uniqueKeysWithValues: peers.map { ($0.peerID, $0.endpoint) })
        candidates = peers
            .filter { !pairedPeers.isPaired($0.peerID) }
            .map { Candidate(peerID: $0.peerID, name: $0.name.isEmpty ? "未知的 Mac" : $0.name) }
    }

    private func fail(_ reason: String) {
        resetSession(sendAbort: false)
        phase = .failed(reason)
    }

    private func sendAbortAndReset() {
        resetSession(sendAbort: true)
    }

    private func resetSession(sendAbort: Bool) {
        if sendAbort, let channel {
            Task {
                try? await channel.send(PairingMessageCoding.encode(.abort))
                channel.close()
            }
        } else {
            channel?.close()
        }
        channel = nil
        privateKey = nil
        remoteHello = nil
        secrets = nil
        localConfirmed = false
        remoteConfirmed = false
    }
}

private extension PairingController.Phase {
    var isMidPairing: Bool {
        switch self {
        case .awaitingResponse, .incomingRequest, .showingSAS: true
        default: false
        }
    }
}
