import ChorusCore
import Foundation

/// 逐裝置遠端控制的生命週期：本機目錄的產生與發佈、遠端目錄的接收、
/// 指令的路由與結果回報。
///
/// 與同檔案主體那一套（`ControlKey` 的整機同步）**刻意不共用路徑**：
/// 那套是要收斂的狀態，走 LWW、受「同步亮度／音量」開關管；這套是遙控，
/// 只動指定端點、不進 LWW、也不因整機同步開關擴散出去。
extension ControlCoordinator {
    /// hello 能力字串。雙方都宣告了才交換目錄與逐端點訊息。
    static let deviceDirectoryCapability = "devices.v1"

    // MARK: - 本機目錄

    /// 裝置清單或能力變動 → 重建目錄並發佈。
    ///
    /// 去抖 400ms：睡醒、插拔 Thunderbolt 機座時，顯示器與音訊裝置會在
    /// 一兩秒內連環重新宣告十幾次。每一次都發一份完整目錄不只浪費頻寬，
    /// 還會把版本號推高、讓對方正在飛的逐端點回報全部作廢。
    func scheduleDirectoryPublish() {
        directoryPublishTask?.cancel()
        directoryPublishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.publishDirectory()
        }
    }

    /// 立刻重建並發佈（連線建立、對方主動查詢時走這條）。
    func publishDirectory(to peerID: String? = nil) {
        directoryPublishTask?.cancel()
        directoryPublishTask = nil
        let endpoints = buildLocalEndpoints()
        // 內容沒變就不推版本：版本一動，對方所有在飛的逐端點回報都得丟掉。
        var bumped = false
        if endpoints != localEndpoints {
            localEndpoints = endpoints
            directoryVersion &+= 1
            bumped = true
        }
        // 版本真的動了就**一定**要發給所有人，即使這次是為了單一收件人而呼叫的。
        // 否則會是這樣：去抖中的廣播被取消 → 版本悄悄加一 → 只有新連上的那位
        // 拿到新版本，其他人永遠停在舊版；而逐端點回報要求版本完全相等，
        // 他們從此再也收不到任何現值更新，直到下一次裝置插拔才解套。
        let recipients = (bumped || peerID == nil)
            ? directoryCapablePeers()
            : [peerID].compactMap { $0 }
        for recipient in Set(recipients).union(peerID.map { [$0] } ?? []) {
            sendDirectory(to: recipient)
        }
    }

    private func sendDirectory(to peerID: String) {
        guard supportsDeviceDirectory(peerID) else { return }
        // session 識別還沒建立就送不出去，而這是**永久性**的失敗：版本已經推上去，
        // 這位 peer 卻拿不到新目錄，之後每一筆逐端點回報都會因為版本對不上而被
        // 丟掉——滑桿從此不動，畫面上卻什麼異常都看不到。
        // 目前 session 建立與發佈在同一條同步路徑上，這個 guard 打不到；
        // 留一行 log 是為了萬一以後有人把順序拆開時，症狀是可以 grep 的。
        guard let sessionID = directorySessionID(for: peerID) else {
            ChorusLog.devices.notice("目錄未送出（尚無 session 識別）peer=\(peerID) 版本=\(directoryVersion)")
            return
        }
        sessionManager?.send(
            Envelope(msg: .deviceDirectory(DeviceDirectory(
                peerID: localPeerID,
                sessionID: sessionID,
                version: directoryVersion,
                endpoints: localEndpoints
            ))),
            to: peerID
        )
    }

    /// 單一端點的現值變化 → 逐端點回報。
    ///
    /// 不重建整份目錄：拖曳滑桿一秒會產生數十次變化，而端點**清單**沒有變。
    /// 佇列會把同一個 (端點, 能力) 的中間值併成最新一筆。
    func reportEndpointValue(
        kind: RemoteEndpointKind,
        deviceID: String,
        capability: RemoteEndpointCapability,
        value: Double
    ) {
        guard let index = localEndpoints.firstIndex(where: {
            $0.kind == kind && $0.deviceID == deviceID
        }) else {
            // 目錄還沒重建就先變值（轉送目標剛切換、螢幕剛醒來）——去抖的 400ms
            // 內是正常現象，下一次發佈就會帶上正確的值。但如果它一直出現，
            // 代表某個端點永遠不在目錄裡，遠端的滑桿會安靜地停住。
            logDroppedReport(kind: kind, deviceID: deviceID, capability: capability)
            return
        }
        guard localEndpoints[index].values[capability.rawValue] != value else { return }
        localEndpoints[index].values[capability.rawValue] = value
        for peerID in directoryCapablePeers() {
            guard let sessionID = directorySessionID(for: peerID) else { continue }
            sessionManager?.send(
                Envelope(msg: .endpointState(EndpointStateUpdate(
                    sessionID: sessionID,
                    version: directoryVersion,
                    deviceID: deviceID,
                    kind: kind,
                    capability: capability,
                    value: value
                ))),
                to: peerID
            )
        }
    }

    /// 連續重複的丟棄只記一次：拖曳滑桿一秒會產生數十筆，全部記下來
    /// 只會把診斷紀錄洗掉，而我們要看的是「哪個端點一直不在目錄裡」。
    private func logDroppedReport(
        kind: RemoteEndpointKind,
        deviceID: String,
        capability: RemoteEndpointCapability
    ) {
        let key = "\(kind.rawValue)|\(deviceID)|\(capability.rawValue)"
        guard lastDroppedReportKey != key else { return }
        lastDroppedReportKey = key
        ChorusLog.devices.notice("回報丟棄（端點不在目錄裡）\(key) 版本=\(directoryVersion)")
    }

    private func buildLocalEndpoints() -> [RemoteEndpoint] {
        let displays = (displayManager?.displays ?? []).map { model in
            LocalDeviceDirectory.DisplayInput(
                uuid: model.uuid,
                name: model.name,
                isBuiltin: model.isBuiltin,
                brightness: model.brightness,
                offset: settings.ambientDisplayOffsets[model.uuid] ?? 0
            )
        }
        let audio = (audioManager?.directoryAudioInputs() ?? [])
        return LocalDeviceDirectory.endpoints(displays: displays, audio: audio)
    }

    // MARK: - 連線生命週期

    /// 連上線：換一個新的 session 識別，並把完整目錄推過去。
    ///
    /// 每條連線一個新識別，是「上一次連線晚到的回報不可以復活已移除端點」
    /// 這條規則的依據——對方看到 session 不同就知道要整份換掉。
    func deviceDirectorySessionEstablished(_ peerID: String) {
        directorySessions[peerID] = UUID()
        guard supportsDeviceDirectory(peerID) else { return }
        publishDirectory(to: peerID)
        // 對方的清單與現值也要重新拿：斷線期間它可能插拔過裝置。
        // **不主動把舊快取寫回對方硬體**——重新顯示只是顯示。
        requestDeviceDirectory(from: peerID)
    }

    func deviceDirectorySessionClosed(_ peerID: String) {
        directorySessions.removeValue(forKey: peerID)
        // 立刻從亮度、音量與配置圖的操作項目移除。管理設定另有持久化的
        // 名稱，離線記錄不會不見。
        remoteDevices.clear(peerID: peerID)
    }

    func requestDeviceDirectory(from peerID: String) {
        guard supportsDeviceDirectory(peerID) else { return }
        sessionManager?.send(Envelope(msg: .deviceDirectoryQuery(DeviceDirectoryQuery())), to: peerID)
    }

    /// 對方宣告了逐裝置目錄能力嗎。沒有的話一則新訊息都不送——
    /// 舊版 peer 雖然會安全地丟棄，但送了也只是白費。
    func supportsDeviceDirectory(_ peerID: String) -> Bool {
        pairedPeers?.peers.first { $0.peerID == peerID }?
            .capabilities?.contains(Self.deviceDirectoryCapability) ?? false
    }

    private func directoryCapablePeers() -> [String] {
        (sessionManager?.connectedPeerIDs ?? []).filter(supportsDeviceDirectory)
    }

    private func directorySessionID(for peerID: String) -> UUID? {
        directorySessions[peerID]
    }

    // MARK: - 遙控（控制端）

    /// 對遠端端點下指令。滑桿在收到結果之前顯示待套用值。
    func sendEndpointCommand(
        _ endpoint: RemoteEndpointID,
        capability: RemoteEndpointCapability,
        value: Double
    ) {
        guard supportsDeviceDirectory(endpoint.peerID) else { return }
        let command = EndpointCommand(
            deviceID: endpoint.deviceID,
            kind: endpoint.kind,
            capability: capability,
            value: value
        )
        remoteDevices.commandSent(
            id: command.id,
            endpoint: endpoint,
            capability: capability,
            value: value
        ) { [weak self] id in
            self?.remoteDevices.commandTimedOut(id)
        }
        sessionManager?.send(Envelope(msg: .endpointCommand(command)), to: endpoint.peerID)
    }

    // MARK: - 收訊

    func handleDeviceMessage(peerID: String, _ message: SyncMessage) -> Bool {
        switch message {
        case .deviceDirectoryQuery:
            publishDirectory(to: peerID)
            return true
        case let .deviceDirectory(directory):
            if remoteDevices.apply(directory, from: peerID) {
                rememberRemoteEndpointNames(directory)
            }
            return true
        case let .endpointState(update):
            remoteDevices.apply(update, from: peerID)
            return true
        case let .endpointCommand(command):
            executeEndpointCommand(command, from: peerID)
            return true
        case let .endpointCommandResult(result):
            remoteDevices.commandCompleted(result)
            return true
        default:
            return false
        }
    }

    /// 離線的端點在管理設定裡仍要看得出是哪一台，所以名稱要留下來。
    /// 逐螢幕差異值一併快取，供光環境分析的還原值使用。
    private func rememberRemoteEndpointNames(_ directory: DeviceDirectory) {
        var names = settings.remoteEndpointNames
        var offsets = settings.remoteDisplayOffsets
        for endpoint in directory.endpoints {
            let key = RemoteEndpointID(
                peerID: directory.peerID,
                kind: endpoint.kind,
                deviceID: endpoint.deviceID
            ).storageKey
            names[key] = endpoint.name
            if let offset = endpoint.value(.brightnessOffset) {
                offsets[key] = offset
            }
        }
        if names != settings.remoteEndpointNames { settings.remoteEndpointNames = names }
        if offsets != settings.remoteDisplayOffsets { settings.remoteDisplayOffsets = offsets }
    }

    // MARK: - 執行（被控端）

    /// 套用一筆遠端端點指令並回報結果。
    ///
    /// 三個規則：
    /// 1. 端點不在就回 `unavailable`，**不退回控制其他裝置**——遙控「第二台
    ///    螢幕」時它剛被拔掉，把指令套到第一台是最糟的失敗方式。
    /// 2. 回報的是硬體**確認後**的值（clamp、量化之後），不是我們收到的值。
    /// 3. 不廣播：這是對單一端點的遙控，不是整機狀態變更。整機同步開關
    ///    開著也不該讓它擴散到其他端點。
    private func executeEndpointCommand(_ command: EndpointCommand, from peerID: String) {
        let applied = applyEndpointCommand(command)
        let result: EndpointCommandResult = switch applied {
        case let .applied(value):
            EndpointCommandResult(id: command.id, outcome: .applied, value: value)
        case .missing:
            EndpointCommandResult(
                id: command.id,
                outcome: .unavailable,
                message: String(localized: "這個裝置已經不在了")
            )
        case .unsupported:
            EndpointCommandResult(
                id: command.id,
                outcome: .failed,
                message: String(localized: "這個裝置不支援這項控制")
            )
        }
        sessionManager?.send(Envelope(msg: .endpointCommandResult(result)), to: peerID)
    }

    private enum EndpointApplyOutcome {
        case applied(Double)
        /// 端點已不存在。
        case missing
        /// 端點還在，但沒有這項能力。
        case unsupported
    }

    private func applyEndpointCommand(_ command: EndpointCommand) -> EndpointApplyOutcome {
        switch command.kind {
        case .display:
            guard let displayManager,
                  displayManager.displays.contains(where: { $0.uuid == command.deviceID })
            else { return .missing }
            switch command.capability {
            case .brightness:
                let value = min(max(command.value, 0), 1)
                displayManager.applyBrightness(value, toUUID: command.deviceID)
                return .applied(value)
            case .brightnessOffset:
                // 沒有自動亮度控制器就是寫不進去。optional chain 會靜靜吞掉，
                // 回報成功等於騙對方「已套用」，它的滑桿會停在一個沒有發生的值。
                guard let autoController else { return .unsupported }
                let value = min(max(command.value, -0.5), 0.5)
                autoController.setDisplayOffset(value, for: command.deviceID)
                return .applied(value)
            default:
                return .unsupported
            }
        case .audioOutput:
            guard let audioManager else { return .missing }
            switch command.capability {
            case .volume:
                guard let value = audioManager.applyEndpointVolume(
                    min(max(command.value, 0), 1),
                    toUID: command.deviceID
                ) else { return audioManager.hasDevice(uid: command.deviceID) ? .unsupported : .missing }
                return .applied(value)
            case .mute:
                guard let value = audioManager.applyEndpointMute(
                    command.value > 0.5,
                    toUID: command.deviceID
                ) else { return audioManager.hasDevice(uid: command.deviceID) ? .unsupported : .missing }
                return .applied(value ? 1 : 0)
            default:
                return .unsupported
            }
        default:
            return .unsupported
        }
    }
}
