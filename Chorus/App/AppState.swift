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
    /// 限時場景（B7）：套用場景 → 倒數 → 結束時原樣放回去。
    let focus: FocusSessionController
    /// 限時場景結束時的系統通知（B7-3）。預設關。
    let focusNotifier: any FocusNotifying
    /// 設定備份到 iCloud Drive（B8）。只寫不讀；預設關。
    let cloudBackup: CloudBackup
    let tapEngine: TapEngine
    let autoEq: AutoEqCatalog
    /// 可用的 AU effect 清單（AU-3；只掃描不實例化，永遠安全）。
    let auCatalog = AUEffectCatalog()
    /// 音訊調音顧問（EQ＋AU 推薦；沿用光環境顧問的引擎層）。
    let audioTuner: AudioTuningAdvisor
    let uiTranslator: UITranslator
    let alertVolume: AlertVolumeController
    let automationEvents: AutomationEventHub
    let automationServer: ControlHTTPServer

    init(instance: InstanceConfig = .current) {
        self.instance = instance
        let settings = SettingsStore(defaults: instance.defaults)
        self.settings = settings
        // 使用者自翻的介面語言要在**任何 View 建立前**掛上 Bundle.main
        let translationStore = UITranslationStore(
            directory: UITranslationStore.defaultDirectory(instance: instance, environment: ProcessInfo.processInfo.environment)
        )
        if let language = settings.uiTranslationLanguage {
            if translationStore.installOverride(language: language) {
                ChorusLog.app.notice("介面翻譯覆蓋已掛上：\(language)")
            } else {
                ChorusLog.app.notice("介面翻譯 \(language) 的檔不在，退回內建語言")
            }
        }
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
        alertVolume = AlertVolumeController()
        audioManager.tapEngine = tapEngine
        tapEngine.stateChangedHandler = { [weak audioManager] in
            audioManager?.refreshBridges()
        }
        coordinator.tapEngine = tapEngine
        // 與光環境顧問共用同一份引擎 registry（設定頁只有一組引擎選擇）
        audioTuner = AudioTuningAdvisor(
            settings: settings,
            registry: advisor.registry,
            tapEngine: tapEngine,
            audioManager: audioManager,
            catalog: auCatalog
        )
        uiTranslator = UITranslator(store: translationStore, settings: settings, registry: advisor.registry)

        sceneStore = SceneStore(defaults: instance.defaults)
        automation = AutomationExecutor(
            settings: settings,
            displayManager: displayManager,
            audioManager: audioManager,
            tapEngine: tapEngine,
            alertVolume: alertVolume,
            autoBrightness: autoBrightness,
            keepAwake: keepAwake,
            coordinator: coordinator,
            pairedPeers: pairedPeers,
            sessionManager: sessionManager,
            scenes: sceneStore
        )

        focus = FocusSessionController(settings: settings, executor: automation, scenes: sceneStore)
        AppStateRegistry.focus = focus
        automation.focus = focus
        focusNotifier = FocusNotifier()
        focus.notifier = focusNotifier
        // peer 連上就補送欠它的跨機還原（B7-4）
        coordinator.peerConnectedHandler = { _ in
            MainActor.assumeIsolated { AppStateRegistry.focus?.retryPendingRestores() }
        }

        cloudBackup = CloudBackup(
            files: CloudBackupFiles(
                // `--cloud-root` 是 E2E 的覆寫：同機雙實例不該把東西寫進
                // 使用者真的 iCloud Drive
                root: instance.cloudRoot.map { URL(fileURLWithPath: $0) }
                    ?? CloudBackupFiles.defaultRoot(),
                deviceName: instance.deviceDisplayName,
                deviceID: instance.peerID
            ),
            settings: settings,
            scenes: sceneStore
        )
        AppStateRegistry.cloudBackup = cloudBackup

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
        focus.events = automationEvents

        // 綁定型的兩個模式是唯一跨重啟保留的（設定上互斥，螢幕優先）
        if let uuid = settings.keepAwakeDisplayUUID {
            keepAwake.activate(.whileDisplayConnected(uuid: uuid))
        } else if let bundleID = settings.keepAwakeAppBundleID {
            keepAwake.activate(.whileAppRunning(bundleID: bundleID))
        }

        displayManager.start()
        audioManager.start()
        sessionManager.start()
        autoBrightness.start()
        mediaKeys.updateActivation()
        virtualDriver.refreshStatus()
        automationServer.updateActivation()
        tapEngine.start()
        // 上次沒正常結束時把限時場景接回來。**要等列舉完**——顯示器與音訊
        // 裝置還沒到齊時還原會誤判「裝置已不在」，所以是延後的，不在這裡直接跑
        focus.scheduleResume()
        cloudBackup.updateActivation()

        let info = Bundle.main.infoDictionary
        ChorusLog.app.notice(
            "啟動 \(info?["CFBundleShortVersionString"] ?? "?") (build \(info?["CFBundleVersion"] ?? "?")) "
            + "instance=\(instance.name ?? "default") macOS \(ProcessInfo.processInfo.operatingSystemVersionString) "
            + "log=\(DiagnosticLog.shared.fileURL.path)"
        )
    }
}
