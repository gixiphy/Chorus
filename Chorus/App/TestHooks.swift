#if DEBUG
import ChorusCore
import Foundation

/// DEBUG 專用測試掛鉤：
/// - `--state-dump <path>`：每秒把可觀察狀態寫成 JSON，供無頭 E2E 測試斷言。
/// - DistributedNotificationCenter "com.hermes.Chorus.test"（userInfo:
///   {instance, action}）：驅動配對流程（beginPairing / requestPairFirst /
///   acceptIncoming / confirmSAS / endPairing），不需要 UI。
@MainActor
final class TestHooks {
    static let notificationName = Notification.Name("com.hermes.Chorus.test")

    private let appState: AppState
    private var dumpTask: Task<Void, Never>?
    private var observer: (any NSObjectProtocol)?
    /// 最近一次 `control` 動作的回應，寫進 state dump 供斷言。
    private var lastControlResponse: ControlResponse?

    init(appState: AppState) {
        self.appState = appState

        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName,
            object: nil,
            queue: .main
        ) { note in
            let info = (note.userInfo as? [String: String]) ?? [:]
            Task { @MainActor in
                TestSupport.hooks?.handle(info)
            }
        }

        if let path = Self.argumentValue("--state-dump") {
            startDumpLoop(to: URL(fileURLWithPath: path))
        }
    }

    private static func argumentValue(_ flag: String) -> String? {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }

    private func handle(_ info: [String: String]) {
        let myInstance = appState.instance.name ?? "default"
        guard info["instance"] == myInstance else { return }
        switch info["action"] {
        case "beginPairing":
            appState.pairing.begin()
        case "requestPairFirst":
            if let candidate = appState.pairing.candidates.first {
                appState.pairing.requestPair(with: candidate)
            }
        case "requestPairNamed":
            // 依名稱選候選者：同機 E2E 時網路上可能同時有正式 app 與其他 Mac，
            // requestPairFirst 會挑錯對象。
            if let name = info["value"],
               let candidate = appState.pairing.candidates.first(where: { $0.name.contains(name) }) {
                appState.pairing.requestPair(with: candidate)
            }
        case "requestPairLoopback":
            // notify.swift 只會帶 value；port 是舊的鍵名，保留相容
            if let port = (info["port"] ?? info["value"]).flatMap(UInt16.init) {
                appState.pairing.requestPair(host: "127.0.0.1", port: port)
            }
        case "acceptIncoming":
            appState.pairing.acceptIncoming()
        case "confirmSAS":
            appState.pairing.confirmSAS()
        case "endPairing":
            appState.pairing.end()
        case "setBrightness":
            if let value = info["value"].flatMap(Double.init),
               let display = appState.displayManager.displays.first {
                appState.displayManager.setBrightness(value, for: display)
            }
        case "setVolume":
            if let value = info["value"].flatMap(Double.init),
               let device = appState.audioManager.defaultDevice {
                appState.audioManager.setVolume(value, for: device)
            }
        case "setBrightnessUUID":
            // value = "<uuid>:<0–1>"；指定顯示器（測試後還原原值用）
            if let raw = info["value"] {
                let parts = raw.split(separator: ":")
                if parts.count == 2, let value = Double(parts[1]),
                   let display = appState.displayManager.displays.first(where: { $0.uuid == parts[0] }) {
                    appState.displayManager.setBrightness(value, for: display)
                }
            }
        case "setAutoBrightness":
            if let value = info["value"] {
                appState.autoBrightness.setAutoEnabled(value == "1")
            }
        case "injectLux":
            if let value = info["value"].flatMap(Double.init) {
                appState.autoBrightness.injectLux(value)
            }
        case "excludeAllAuto":
            // 同機 E2E：讓這個實例只回報 lux、不寫實體螢幕（兩實例共用同一片硬體）
            appState.settings.ambientExcludedDisplays = Set(appState.displayManager.displays.map(\.uuid))
        case "saveScenario":
            if let name = info["value"] {
                appState.scenarios.createFromCurrent(named: name)
            }
        case "switchScenario":
            if let name = info["value"],
               let scenario = appState.scenarios.scenarios.first(where: { $0.name == name }) {
                appState.scenarios.switchTo(scenario.id)
            }
        case "simulateMediaKey":
            // value = NX keyCode（0=音量+ 1=音量- 7=mute 2=亮度+ 3=亮度-）；
            // 直接走路由驗證接管條件與套用路徑，不經 CGEvent tap
            if let code = info["value"].flatMap(Int32.init) {
                _ = appState.mediaKeys.debugSimulate(keyCode: code)
            }
        case "injectAdvice":
            // value = LightingAdvice JSON；走 FakeAdviceProvider 完整管線
            if let json = info["value"] {
                appState.advisor.debugInject(adviceJSON: json)
            }
        case "setDisplayPower":
            // value = "<uuid>:<0|1>"，或只給 "0"/"1" 代表全部顯示器
            if let raw = info["value"] {
                let parts = raw.split(separator: ":")
                if parts.count == 2, let on = Int(parts[1]),
                   let display = appState.displayManager.displays.first(where: { $0.uuid == parts[0] }) {
                    appState.displayManager.setDisplayPower(on == 1, for: display)
                } else if let on = Int(raw) {
                    appState.displayManager.applyCommandDisplayPower(on == 1)
                }
            }
        case "remoteCommand":
            // value = "<key>:<number>"，送給第一個已連線的 peer。
            // command 通道（非 stateUpdate）先前沒有 E2E 覆蓋，B3 的
            // setDisplayPower／setKeepAwake 正是走這條路。
            if let raw = info["value"] {
                let parts = raw.split(separator: ":")
                let peerID = appState.sessionManager.connectionStates.first {
                    if case .connected = $0.value { return true }
                    return false
                }?.key
                if parts.count == 2, let value = Double(parts[1]), let peerID {
                    let key: ControlKey? = switch parts[0] {
                    case "displayPower": .displayPower(displayUUID: nil)
                    case "keepAwake": .keepAwake(displayUUID: nil)
                    default: nil
                    }
                    if let key {
                        appState.coordinator.sendRemoteCommand(to: peerID, key: key, value: value)
                    }
                }
            }
        case "control":
            // value = ControlRequest JSON。走動詞層的完整路徑（驗證＋執行），
            // 不需要開 HTTP server 也不需要 token——B4-1 的 E2E 入口。
            if let json = info["value"], let data = json.data(using: .utf8),
               let request = try? JSONDecoder().decode(ControlRequest.self, from: data) {
                lastControlResponse = appState.automation.execute(request)
            } else {
                lastControlResponse = .failure(.badValue(
                    info["value"] ?? "",
                    hint: "不是合法的 ControlRequest JSON"
                ))
            }
        case "automationServer":
            // value = "1"/"0"；port 可用 "1:PORT" 指定（同機兩實例要錯開）
            if let raw = info["value"] {
                let parts = raw.split(separator: ":")
                if parts.count == 2, let port = UInt16(parts[1]) {
                    appState.settings.automationServerPort = port
                }
                appState.settings.automationServerEnabled = parts.first == "1"
                appState.automationServer.updateActivation()
            }
        case "restoreAllDisplayPower":
            appState.displayManager.restoreAllDisplayPower()
        case "emergencyGesture":
            // value = 按壓次數（預設 8）；走真正的手勢狀態機
            appState.emergencyRestore.debugSimulateCommandPresses(Int(info["value"] ?? "") ?? 8)
        case "setKeepAwake":
            // value 依 KeepAwakePlanner 編碼：0 = 關、負值 = 無限期、正值 = 秒數；
            // "display:<uuid>" 綁定螢幕
            if let raw = info["value"] {
                if raw.hasPrefix("display:") {
                    appState.keepAwake.activate(.whileDisplayConnected(uuid: String(raw.dropFirst(8))))
                } else if let value = Double(raw) {
                    appState.keepAwake.activate(KeepAwakePlanner.decode(value))
                }
            }
        case "applyAdvice":
            appState.advisor.debugApplyAll()
        case "undoAdvice":
            appState.advisor.undoLastApply()
        default:
            break
        }
    }

    private static func describe(_ mode: KeepAwakeMode) -> String {
        switch mode {
        case .off: "off"
        case .indefinite: "indefinite"
        case let .duration(seconds): "duration:\(Int(seconds))"
        case let .whileDisplayConnected(uuid): "display:\(uuid)"
        }
    }

    private func startDumpLoop(to url: URL) {
        dumpTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.writeDump(to: url)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func writeDump(to url: URL) {
        var pairingPhase: String
        switch appState.pairing.phase {
        case .idle: pairingPhase = "idle"
        case .browsing: pairingPhase = "browsing"
        case .awaitingResponse: pairingPhase = "awaitingResponse"
        case .incomingRequest: pairingPhase = "incomingRequest"
        case let .showingSAS(code, _, local, remote): pairingPhase = "showingSAS:\(code):\(local):\(remote)"
        case let .completed(name): pairingPhase = "completed:\(name)"
        case let .failed(reason): pairingPhase = "failed:\(reason)"
        }

        let dump: [String: Any] = [
            "peerID": appState.instance.peerID,
            "instance": appState.instance.name ?? "default",
            "pairedPeers": appState.pairedPeers.peers.map(\.peerID),
            "connectionStates": appState.sessionManager.connectionStates.mapValues { state in
                switch state {
                case .connected: "connected"
                case .connecting: "connecting"
                case .disconnected: "disconnected"
                }
            },
            "pairingPhase": pairingPhase,
            "pairingListenerState": appState.pairing.listenerState,
            "pairingBrowserState": appState.pairing.browserState,
            "candidates": appState.pairing.candidates.map(\.name),
            "displays": appState.displayManager.displays.map { display in
                [
                    "uuid": display.uuid,
                    "name": display.name,
                    "backend": display.backend.rawValue,
                    "brightness": display.brightness,
                    "poweredOff": display.isPoweredOff,
                    "powerLayer": display.powerLayer.rawValue,
                ] as [String: Any]
            },
            "audioDevices": appState.audioManager.devices.map { device in
                [
                    "uid": device.uid,
                    "name": device.name,
                    "volume": device.volume,
                    "muted": device.muted,
                    "isDefault": device.isDefault,
                ] as [String: Any]
            },
            "scenarios": [
                "active": appState.scenarios.activeScenario.map { $0.name as Any } ?? NSNull(),
                "names": appState.scenarios.scenarios.map(\.name),
            ] as [String: Any],
            "mediaKeys": [
                "enabled": appState.settings.mediaKeyCaptureEnabled,
                "tapActive": appState.mediaKeys.tapActive,
                "trusted": appState.mediaKeys.lastTrusted,
            ] as [String: Any],
            "advisor": [
                "isAnalyzing": appState.advisor.isAnalyzing,
                "hasResult": appState.advisor.result != nil,
                "resultOffsets": appState.advisor.result?.advice.offsets.count ?? 0,
                "canUndo": appState.advisor.canUndo,
                "historyCount": appState.advisor.history.count,
                "lastError": appState.advisor.lastErrorMessage.map { $0 as Any } ?? NSNull(),
                "activeEngine": appState.advisor.registry.activeEngine.map { $0.id as Any } ?? NSNull(),
            ] as [String: Any],
            "keepAwake": [
                "mode": Self.describe(appState.keepAwake.mode),
                "holding": appState.keepAwake.isHolding,
                "remaining": appState.keepAwake.remainingSeconds.map { $0 as Any } ?? NSNull(),
                "preventsSystemSleep": appState.keepAwake.alsoPreventSystemSleep,
            ] as [String: Any],
            "lastControl": lastControlResponse
                .flatMap { try? JSONEncoder().encode($0) }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull(),
            "automationServer": [
                "enabled": appState.settings.automationServerEnabled,
                "running": appState.automationServer.isRunning,
                "port": Int(appState.settings.automationServerPort),
                "token": appState.settings.automationServerEnabled
                    ? appState.automationServer.currentToken() as Any
                    : NSNull(),
                "lastError": appState.automationServer.lastError.map { $0 as Any } ?? NSNull(),
            ] as [String: Any],
            "emergencyRestore": [
                "armed": appState.emergencyRestore.isArmed,
                "trusted": appState.emergencyRestore.isTrusted,
            ] as [String: Any],
            "ambient": [
                "autoEnabled": appState.settings.autoBrightnessEnabled,
                "hasLocalSensor": appState.autoBrightness.hasLocalSensor,
                "currentLux": appState.autoBrightness.currentLux.map { $0 as Any } ?? NSNull(),
                "baselineLux": appState.autoBrightness.baselineLux.map { $0 as Any } ?? NSNull(),
                "baselineSource": appState.autoBrightness.baselineSourceID.map { $0 as Any } ?? NSNull(),
                "displayOffsets": appState.settings.ambientDisplayOffsets,
                "deviceOffset": appState.settings.ambientDeviceOffset,
            ] as [String: Any],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dump, options: [.sortedKeys]) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

@MainActor
enum TestSupport {
    static var hooks: TestHooks?
}
#endif
