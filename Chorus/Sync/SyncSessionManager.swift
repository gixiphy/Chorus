import AppKit
import ChorusCore
import Foundation
import Network
import Observation

/// full-mesh 成員管理：探索已配對裝置、建立/接受 TLS-PSK 連線、hello 驗證、
/// 斷線重撥。連線去重規則：peerID 字典序較小者當撥號方。
///
/// 生命週期規則在 ChorusCore 的 `PeerSessionSlots`：每個 peer 同時一件工作、
/// 每件工作帶 generation、任何前期失敗都退避。這裡把 Network.framework 的事件
/// 接上去，並且**每個 Task 都有擁有者**——睡醒時收得乾淨，舊工作晚到的結果
/// 動不到新連線。
@MainActor
@Observable
final class SyncSessionManager {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
    }

    /// 連線 ready 之後等對方 hello 的期限（含我方送出 hello）。
    static let helloTimeout: Duration = .seconds(5)
    /// 還沒完成 hello 的連線上限（撥出＋撥入）。未認證的連線不能無限佔資源。
    static let maxPendingHandshakes = 8

    /// peerID → 連線狀態（UI 顯示用）。
    private(set) var connectionStates: [String: ConnectionState] = [:]

    /// 同步 browser 的最近狀態；NoAuth／waiting 表示區域網路權限有問題。
    private(set) var browserStateDescription = ""
    /// 同步 listener 的最近狀態（診斷用）。
    private(set) var listenerStateDescription = ""

    /// 探索管道異常（權限被拒等）→ UI 顯示疑難排解提示。
    var hasDiscoveryProblem: Bool {
        browserStateDescription.contains("NoAuth") || browserStateDescription.hasPrefix("waiting")
    }

    @ObservationIgnored private let instance: InstanceConfig
    @ObservationIgnored private let pairedPeers: PairedPeersStore
    @ObservationIgnored private let advertiser = BonjourAdvertiser()
    @ObservationIgnored private let browser = BonjourBrowserService()
    @ObservationIgnored private var slots: PeerSessionSlots
    @ObservationIgnored private let origin = ContinuousClock.now

    private struct Session {
        let connection: PeerConnection
        let generation: UInt64
    }

    /// 已完成 hello 的 session。
    @ObservationIgnored private var sessions: [String: Session] = [:]
    /// 每條連線（撥出或撥入）一個 task：連線 → hello → 收訊迴圈 → 收尾。
    @ObservationIgnored private var connectionTasks: [ObjectIdentifier: (connection: PeerConnection, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var pendingHandshakes: Set<ObjectIdentifier> = []
    @ObservationIgnored private var retryTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var serviceTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var listenerRetryTask: Task<Void, Never>?
    @ObservationIgnored private var listenerBackoff = RedialBackoff()
    @ObservationIgnored private var latestEndpoints: [String: NWEndpoint] = [:]
    @ObservationIgnored private var lastHeard: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    /// 有 peer 連線時持有，避免 App Nap 拖慢心跳與同步。
    @ObservationIgnored private var activityToken: (any NSObjectProtocol)?
    @ObservationIgnored private static let log = ChorusLog(category: "sync")

    /// 收到的 envelope 交給上層（M5 的 ControlCoordinator）。ping/pong 在本層處理。
    @ObservationIgnored var envelopeHandler: ((_ peerID: String, _ envelope: Envelope) -> Void)?
    /// 新 session 建立（hello 完成）時通知上層，用於互換 fullState。
    @ObservationIgnored var sessionEstablishedHandler: ((_ peerID: String) -> Void)?
    /// Session 關閉時通知上層（環境光來源 failover 用）。
    @ObservationIgnored var sessionClosedHandler: ((_ peerID: String) -> Void)?
    /// 本機能力（hello 與 Bonjour TXT 用；AppState 在 start() 前設定）。
    @ObservationIgnored var localCapabilities: [String] = ["display", "audio"]

    var localPeerID: String { instance.peerID }

    init(instance: InstanceConfig, pairedPeers: PairedPeersStore) {
        self.instance = instance
        self.pairedPeers = pairedPeers
        slots = PeerSessionSlots(localPeerID: instance.peerID)
        for peer in pairedPeers.peers {
            connectionStates[peer.peerID] = .disconnected
        }
    }

    private var now: Duration { origin.duration(to: .now) }

    /// 重複呼叫無副作用。
    func start() {
        guard !slots.isRunning else { return }
        slots.start()
        restartAdvertiser()
        browser.start(myPeerID: instance.peerID)
        let browser = browser
        let advertiser = advertiser
        serviceTasks = [
            Task { [weak self] in
                for await peers in browser.discoveries {
                    self?.handleDiscoveries(peers)
                }
            },
            Task { [weak self] in
                for await nwConnection in advertiser.inboundConnections {
                    self?.handleInbound(nwConnection)
                }
            },
            Task { [weak self] in
                for await state in browser.states {
                    self?.browserStateDescription = state
                }
            },
            Task { [weak self] in
                for await event in advertiser.events {
                    self?.handleListenerEvent(event)
                }
            },
            // 心跳：每 10 秒 ping；30 秒沒聽到任何訊息視為死線（Bonjour Sleep Proxy
            // 會讓已睡眠的 Mac 看似在線，必須靠 application-level 心跳）
            Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    self?.heartbeatTick()
                }
            },
        ]
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }
    }

    /// 睡醒：TCP 連線多半已死但未回報 → 所有工作作廢、重啟 browser、立即重撥。
    private func handleWake() {
        guard slots.isRunning else { return }
        Self.log.notice("睡醒：關閉 \(sessions.count) 條 session、\(connectionTasks.count) 條連線工作，重新撥號")
        let dialNow = slots.reset(peers: pairedPeers.peers.map(\.peerID))
        for task in retryTasks.values { task.cancel() }
        retryTasks = [:]
        let closedPeers = Array(sessions.keys)
        for entry in connectionTasks.values {
            entry.task.cancel()
            entry.connection.close()
        }
        connectionTasks = [:]
        pendingHandshakes = []
        sessions = [:]
        lastHeard = [:]
        updateActivityKeeper()
        for peerID in closedPeers {
            sessionClosedHandler?(peerID)
        }
        refreshAllStates()
        browser.stop()
        browser.start(myPeerID: instance.peerID)
        for peerID in dialNow {
            maybeDial(peerID)
        }
    }

    private func heartbeatTick() {
        let now = ContinuousClock.now
        for (peerID, session) in sessions {
            if let heard = lastHeard[peerID], now - heard > .seconds(30) {
                session.connection.close() // 收訊迴圈結束時走 handleClosed → 重撥
                continue
            }
            send(Envelope(msg: .ping(0)), to: peerID)
        }
    }

    private func updateActivityKeeper() {
        if sessions.isEmpty {
            if let token = activityToken {
                ProcessInfo.processInfo.endActivity(token)
                activityToken = nil
            }
        } else if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.background],
                reason: "Syncing with paired Macs"
            )
        }
    }

    /// 配對集合變更後重建 listener 的 PSK 表。
    func restartAdvertiser() {
        listenerRetryTask?.cancel()
        listenerRetryTask = nil
        let psks = pairedPeers.peers.compactMap { peer -> (identity: String, psk: Data)? in
            pairedPeers.psk(for: peer.peerID).map { (identity: peer.peerID, psk: $0) }
        }
        advertiser.restart(
            peerID: instance.peerID,
            deviceName: instance.deviceDisplayName,
            psks: psks,
            fixedPort: instance.syncListenPort,
            deviceKind: "mac",
            capabilities: localCapabilities
        )
        for peer in pairedPeers.peers {
            if connectionStates[peer.peerID] == nil {
                connectionStates[peer.peerID] = .disconnected
            }
            maybeDial(peer.peerID)
        }
    }

    /// listener 失敗時退避重建；waiting（多半是權限）只記下來，不忙著重試。
    private func handleListenerEvent(_ event: BonjourAdvertiser.ListenerEvent) {
        switch event {
        case .ready:
            listenerStateDescription = "ready"
            listenerBackoff.reset()
        case let .waiting(reason):
            listenerStateDescription = "waiting: \(reason)"
        case let .failed(reason), let .setupFailed(reason):
            listenerStateDescription = "failed: \(reason)"
            guard slots.isRunning, listenerRetryTask == nil else { return }
            let delay = listenerBackoff.next(random: .random(in: 0..<1))
            Self.log.error("同步 listener 失敗（\(reason)），\(OperationMetrics.format(delay)) 後重建")
            listenerRetryTask = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self else { return }
                listenerRetryTask = nil
                restartAdvertiser()
            }
        }
    }

    /// 廣播 envelope 給所有已連線 peer。
    func broadcast(_ envelope: Envelope) {
        for session in sessions.values {
            let connection = session.connection
            Task { try? await connection.send(envelope) }
        }
    }

    /// 送給特定 peer。每次送出都有期限（見 FramedNWConnection.sendTimeout）。
    func send(_ envelope: Envelope, to peerID: String) {
        guard let connection = sessions[peerID]?.connection else { return }
        Task { try? await connection.send(envelope) }
    }

    var connectedPeerIDs: [String] { Array(sessions.keys) }

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
        guard let endpoint = dialEndpoint(for: peerID), pairedPeers.psk(for: peerID) != nil else { return }
        guard case let .start(generation) = slots.requestDial(peerID, endpoint: "\(endpoint)", now: now) else {
            return
        }
        startDial(peerID, generation: generation)
    }

    private func dialEndpoint(for peerID: String) -> NWEndpoint? {
        latestEndpoints[peerID] ?? manualEndpoint(for: peerID)
    }

    /// slot 已經給了這件工作的 generation；這裡只負責真的撥出去。
    private func startDial(_ peerID: String, generation: UInt64) {
        retryTasks.removeValue(forKey: peerID)?.cancel()
        guard let endpoint = dialEndpoint(for: peerID), let psk = pairedPeers.psk(for: peerID) else {
            attemptFailed(peerID, generation: generation, reason: "沒有可用的端點或金鑰")
            return
        }
        guard pendingHandshakes.count < Self.maxPendingHandshakes else {
            attemptFailed(peerID, generation: generation, reason: "握手中的連線已達上限")
            return
        }
        let connection = PeerConnection.dial(
            endpoint: endpoint,
            myPeerID: instance.peerID,
            psk: psk,
            expectedPeerID: peerID,
            onClose: {}
        )
        run(connection, dialedPeer: peerID, generation: generation)
        refreshState(peerID)
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

    private func attemptFailed(_ peerID: String, generation: UInt64, reason: String) {
        if let delay = slots.attemptFailed(peerID, generation: generation, now: now, random: .random(in: 0..<1)) {
            Self.log.notice("連線 \(peerID.prefix(8)) 未建立（\(reason)），\(OperationMetrics.format(delay)) 後重撥")
            scheduleRetry(peerID, generation: generation, after: delay)
        }
        refreshState(peerID)
    }

    private func scheduleRetry(_ peerID: String, generation: UInt64, after delay: Duration) {
        retryTasks[peerID]?.cancel()
        retryTasks[peerID] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            retryTasks[peerID] = nil
            guard case let .start(next) = slots.backoffElapsed(peerID, generation: generation) else { return }
            startDial(peerID, generation: next)
        }
    }

    // MARK: - Inbound

    private func handleInbound(_ nwConnection: NWConnection) {
        guard slots.isRunning, pendingHandshakes.count < Self.maxPendingHandshakes else {
            Self.log.notice("拒絕撥入連線：握手中的連線已達上限")
            nwConnection.cancel()
            return
        }
        let connection = PeerConnection.inbound(connection: nwConnection, onClose: {})
        run(connection, dialedPeer: nil, generation: nil)
    }

    // MARK: - 每條連線的生命週期

    private func run(_ connection: PeerConnection, dialedPeer: String?, generation: UInt64?) {
        let key = ObjectIdentifier(connection)
        pendingHandshakes.insert(key)
        let task = Task { [weak self] in
            await self?.drive(connection, dialedPeer: dialedPeer, generation: generation)
            connection.close()
            self?.pendingHandshakes.remove(key)
            self?.connectionTasks[key] = nil
        }
        connectionTasks[key] = (connection, task)
    }

    /// 連線 → hello → 收訊迴圈。任何一步失敗都回報給 slot（撥號方因此退避重撥）。
    private func drive(_ connection: PeerConnection, dialedPeer: String?, generation: UInt64?) async {
        let key = ObjectIdentifier(connection)
        let metrics = OperationMetrics.shared
        let connectToken = metrics.begin(dialedPeer == nil ? "sync.accept" : "sync.connect")
        do {
            try await connection.start()
            metrics.end(connectToken)
        } catch {
            metrics.end(connectToken, .failure)
            if let dialedPeer, let generation {
                attemptFailed(dialedPeer, generation: generation, reason: "連線失敗")
            }
            return
        }
        if let dialedPeer, let generation {
            guard slots.connectReady(dialedPeer, generation: generation) else { return } // 已作廢
            refreshState(dialedPeer)
        }

        let helloToken = metrics.begin("sync.hello")
        let myHello = Hello(
            peerID: instance.peerID,
            deviceName: instance.deviceDisplayName,
            protocolVersion: ChorusProtocol.version,
            deviceKind: "mac",
            capabilities: localCapabilities
        )
        var iterator = connection.incoming.makeAsyncIterator()
        // 我方 hello 與等對方 hello 共用同一個期限：送出本身卡住也算在內
        let outcome = await HelloWait.awaitHello(
            from: &iterator,
            timeout: Self.helloTimeout,
            clock: ContinuousClock(),
            close: { connection.close() }
        ) {
            if !FaultRegistry.shared.isWithholding(.syncHello) {
                try? await FaultRegistry.shared.inject(.syncHello)
                try? await connection.send(Envelope(msg: .hello(myHello)))
            }
        }
        guard case let .hello(hello) = outcome else {
            metrics.end(helloToken, outcome == .timedOut ? .timeout : .failure)
            if let dialedPeer, let generation {
                attemptFailed(dialedPeer, generation: generation, reason: "hello \(outcome)")
            }
            return
        }
        metrics.end(helloToken)
        pendingHandshakes.remove(key)
        // 睡醒時被作廢的工作可能剛好在取消前收到 hello：不要讓它登記成 session
        guard !Task.isCancelled else { return }

        guard let sessionGeneration = acceptSession(connection, hello: hello, dialGeneration: generation) else {
            if let dialedPeer, let generation {
                attemptFailed(dialedPeer, generation: generation, reason: "hello 驗證未通過")
            }
            return
        }
        while let envelope = await iterator.next(isolation: #isolation) {
            handleEnvelope(peerID: hello.peerID, envelope)
        }
        handleClosed(connection, peerID: hello.peerID, generation: sessionGeneration)
    }

    /// hello 驗證＋重複連線裁決。回傳 session 的 generation；nil 表示這條要關掉。
    private func acceptSession(_ connection: PeerConnection, hello: Hello, dialGeneration: UInt64?) -> UInt64? {
        let peerID = hello.peerID
        // TLS-PSK 已證明對方持有配對金鑰；這裡是 defense in depth
        guard slots.isRunning, pairedPeers.isPaired(peerID) else { return nil }
        if let expected = connection.expectedPeerID, expected != peerID { return nil }
        guard hello.protocolVersion == ChorusProtocol.version else { return nil }
        // 撥號結果已被取代（睡醒、或對方撥進來的 session 先建立）：先確認，
        // 才不會關掉現有 session 之後才發現自己也不能用
        if connection.isDialer {
            guard let dialGeneration, slots.generation(of: peerID) == dialGeneration,
                  slots.phase(of: peerID) == .awaitingHello
            else { return nil }
        }

        if let existing = sessions[peerID] {
            // 兩條連線並存：保留「應然撥號方」（min peerID）建立的那條
            let iAmDialer = instance.peerID < peerID
            let existingPreferred = existing.connection.isDialer == iAmDialer
            if existingPreferred {
                return nil // 關掉新的
            }
            existing.connection.close()
        }

        guard let generation = slots.sessionEstablished(
            peerID, generation: connection.isDialer ? dialGeneration : nil, now: now
        ) else { return nil }
        retryTasks.removeValue(forKey: peerID)?.cancel()
        sessions[peerID] = Session(connection: connection, generation: generation)
        lastHeard[peerID] = ContinuousClock.now
        updateActivityKeeper()
        refreshState(peerID)
        pairedPeers.updateMetadata(
            peerID: peerID,
            deviceName: hello.deviceName,
            deviceKind: hello.deviceKind,
            capabilities: hello.capabilities
        )
        sessionEstablishedHandler?(peerID)
        return generation
    }

    private func handleClosed(_ connection: PeerConnection, peerID: String, generation: UInt64) {
        // 只清掉「目前登記的那條」；重複連線裁決關掉的舊連線不影響新的
        guard sessions[peerID]?.connection === connection else { return }
        sessions[peerID] = nil
        lastHeard[peerID] = nil
        updateActivityKeeper()
        sessionClosedHandler?(peerID)
        if let delay = slots.sessionClosed(peerID, generation: generation, now: now, random: .random(in: 0..<1)) {
            scheduleRetry(peerID, generation: generation, after: delay)
        }
        refreshState(peerID)
    }

    private func handleEnvelope(peerID: String, _ envelope: Envelope) {
        lastHeard[peerID] = ContinuousClock.now
        switch envelope.msg {
        case let .ping(token):
            send(Envelope(msg: .pong(token)), to: peerID)
        default:
            envelopeHandler?(peerID, envelope)
        }
    }

    // MARK: - UI 狀態

    private func refreshState(_ peerID: String) {
        guard connectionStates[peerID] != nil || pairedPeers.isPaired(peerID) else { return }
        let state: ConnectionState = switch slots.phase(of: peerID) {
        case .dialing, .awaitingHello: .connecting
        case .connected: sessions[peerID] != nil ? .connected : .disconnected
        case .idle, .backoff: .disconnected
        }
        if connectionStates[peerID] != state {
            connectionStates[peerID] = state
        }
    }

    private func refreshAllStates() {
        for peerID in connectionStates.keys {
            refreshState(peerID)
        }
    }
}
