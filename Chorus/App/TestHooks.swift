#if DEBUG
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
        case "requestPairLoopback":
            if let port = info["port"].flatMap(UInt16.init) {
                appState.pairing.requestPair(host: "127.0.0.1", port: port)
            }
        case "acceptIncoming":
            appState.pairing.acceptIncoming()
        case "confirmSAS":
            appState.pairing.confirmSAS()
        case "endPairing":
            appState.pairing.end()
        default:
            break
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
