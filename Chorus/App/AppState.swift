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
        displayManager.start()
        audioManager.start()
        sessionManager.start()
    }
}
