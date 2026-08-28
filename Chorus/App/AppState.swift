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
    let advisor: LightingAdvisor
    let mediaKeys: MediaKeyInterceptor
    let scenarios: DeskScenarioStore
    let virtualDriver: VirtualAudioDriverController
    let keepAwake: KeepAwakeController
    let emergencyRestore: EmergencyRestoreMonitor
    let automation: AutomationExecutor
    let sceneStore: SceneStore
    let tapEngine: TapEngine
    let autoEq: AutoEqCatalog
    let automationEvents: AutomationEventHub
    let automationServer: ControlHTTPServer

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
        advisor = LightingAdvisor(
            instance: instance,
            settings: settings,
            displayManager: displayManager,
            pairedPeers: pairedPeers,
            autoBrightness: autoBrightness,
            coordinator: coordinator,
            diagram: diagram
        )

        // 能力（含 "als"）要在 sessionManager.start() 之前設定，Bonjour TXT 與 hello 才帶得到
        var capabilities = ["display", "audio"]
        if sensor.isAvailable { capabilities.append("als") }
        sessionManager.localCapabilities = capabilities
        pairing.localCapabilities = capabilities

        scenarios = DeskScenarioStore(
            instance: instance,
            settings: settings,
            diagram: diagram,
            displayManager: displayManager,
            autoBrightness: autoBrightness
        )
        mediaKeys = MediaKeyInterceptor(
            settings: settings,
            displayManager: displayManager,
            audioManager: audioManager
        )

        virtualDriver = VirtualAudioDriverController()
        audioManager.virtualDriver = virtualDriver

        keepAwake = KeepAwakeController(settings: settings, displayManager: displayManager)
        emergencyRestore = EmergencyRestoreMonitor(displayManager: displayManager)

        displayManager.autoController = autoBrightness
        displayManager.audioManager = audioManager
        displayManager.scenarioStore = scenarios
        displayManager.keepAwake = keepAwake
        displayManager.emergencyRestore = emergencyRestore
        AppStateRegistry.scenarioStore = scenarios
        AppStateRegistry.keepAwake = keepAwake
        coordinator.attachAutoController(autoBrightness)
        coordinator.attachKeepAwake(keepAwake)

        sceneStore = SceneStore(defaults: instance.defaults)
        automation = AutomationExecutor(
            settings: settings,
            displayManager: displayManager,
            audioManager: audioManager,
            autoBrightness: autoBrightness,
            keepAwake: keepAwake,
            coordinator: coordinator,
            pairedPeers: pairedPeers,
            sessionManager: sessionManager,
            scenes: sceneStore
        )

        automationEvents = AutomationEventHub()
        automationServer = ControlHTTPServer(
            settings: settings,
            keychain: KeychainStore(service: instance.keychainService),
            executor: automation,
            events: automationEvents,
            scenes: sceneStore
        )
        coordinator.automationEvents = automationEvents
        displayManager.automationEvents = automationEvents

        let tapRegistry = AudioProcessRegistry()
        #if DEBUG
        let tapBackend: any TapBackend
        if instance.fakeTaps {
            let fake = FakeTapBackend()
            TestSupport.fakeTapBackend = fake
            tapBackend = fake
        } else {
            tapBackend = CoreAudioTapBackend()
        }
        #else
        let tapBackend: any TapBackend = CoreAudioTapBackend()
        #endif
        tapEngine = TapEngine(backend: tapBackend, registry: tapRegistry, settings: settings)
        autoEq = AutoEqCatalog(instance: instance)
        audioManager.tapEngine = tapEngine
        tapEngine.stateChangedHandler = { [weak audioManager] in
            audioManager?.refreshBridges()
        }

        // 「接著這台螢幕時防睡眠」是唯一跨重啟保留的模式
        if let uuid = settings.keepAwakeDisplayUUID {
            keepAwake.activate(.whileDisplayConnected(uuid: uuid))
        }

        displayManager.start()
        audioManager.start()
        sessionManager.start()
        autoBrightness.start()
        mediaKeys.updateActivation()
        virtualDriver.refreshStatus()
        automationServer.updateActivation()
        tapEngine.start()
    }
}
