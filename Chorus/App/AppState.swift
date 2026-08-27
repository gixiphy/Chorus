import Foundation
import Observation

/// App 的根狀態，只在 MainActor 上讀寫。
@MainActor
@Observable
final class AppState {
    let instance: InstanceConfig
    let settings: SettingsStore
    let displayManager: DisplayManager
    let audioManager: AudioDeviceManager
    let pairedPeers: PairedPeersStore
    let sessionManager: SyncSessionManager
    let pairing: PairingController
    let coordinator: ControlCoordinator
    let autoBrightness: AutoBrightnessController
    let diagram: DiagramStore

    init(instance: InstanceConfig = .current) {
        self.instance = instance
        let settings = SettingsStore(defaults: instance.defaults)
        self.settings = settings
        displayManager = DisplayManager(settings: settings)
        audioManager = AudioDeviceManager(settings: settings, displayManager: displayManager)
        pairedPeers = PairedPeersStore(
            defaults: instance.defaults,
            keychain: KeychainStore(service: instance.keychainService)
        )
        sessionManager = SyncSessionManager(instance: instance, pairedPeers: pairedPeers)
        pairing = PairingController(instance: instance, pairedPeers: pairedPeers, sessionManager: sessionManager)
        coordinator = ControlCoordinator(
            localPeerID: instance.peerID,
            settings: settings,
            sessionManager: sessionManager,
            displayManager: displayManager,
            audioManager: audioManager
        )
        let sensor = AmbientLightSensorClient(fakeALS: instance.fakeALS, disabled: instance.disableALS)
        autoBrightness = AutoBrightnessController(
            localPeerID: instance.peerID,
            settings: settings,
            displayManager: displayManager,
            sensor: sensor
        )
        diagram = DiagramStore(instance: instance)

        // 能力（含 "als"）要在 sessionManager.start() 之前設定，Bonjour TXT 與 hello 才帶得到
        var capabilities = ["display", "audio"]
        if sensor.isAvailable { capabilities.append("als") }
        sessionManager.localCapabilities = capabilities
        pairing.localCapabilities = capabilities

        displayManager.autoController = autoBrightness
        coordinator.attachAutoController(autoBrightness)

        displayManager.start()
        audioManager.start()
        sessionManager.start()
        autoBrightness.start()
    }
}
