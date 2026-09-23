import ChorusCore
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
    /// 選單列圖示「調整當下才出現的數字」。
    let statusReadout = StatusReadoutController()
    let pairedPeers: PairedPeersStore
    let sessionManager: SyncSessionManager
    let pairing: PairingController
    let coordinator: ControlCoordinator
    let autoBrightness: AutoBrightnessController
    /// 所在地座標，只供時間排程算日出日落。
    let location: LocationProvider
    let diagram: DiagramStore
    let advisor: LightingAdvisor
    let mediaKeys: MediaKeyInterceptor
    let windowManager: WindowManager
    let virtualDriver: VirtualAudioDriverController
    let keepAwake: KeepAwakeController
    let emergencyRestore: EmergencyRestoreMonitor
    let displayConfiguration: DisplayConfigurationController
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
        // 最先開：啟動本身（列舉、iCloud Drive 探測）的停頓也要量得到
        #if DEBUG
        FaultRegistry.shared.configure(arguments: ProcessInfo.processInfo.arguments)
        #endif
        MainLoopWatchdog.shared.start()
        MemoryPressureMonitor.shared.start()
        // 哨兵要在任何可能 crash 的初始化之前寫下；MetricKit 訂閱與 .ips 掃描在背景
        CrashReportCollector.shared.start()
        // 每一步之後打點：選單出來之前主執行緒花在哪裡（Batch F）
        var timeline = StartupTimeline()
        self.instance = instance
        let settings = SettingsStore(defaults: instance.defaults)
        self.settings = settings
        timeline.mark("settings")
        // 使用者自翻的介面語言要在**任何 View 建立前**掛上 Bundle.main
        let translationStore = UITranslationStore(
            directory: UITranslationStore.defaultDirectory(instance: instance, environment: ProcessInfo.processInfo.environment)
        )
        // 這個行程實際跑的語言：覆蓋掛上了就是自翻語言，否則是使用者選的內建語言
        // （靠 AppleLanguages 生效，選定時就寫好了）或跟隨系統。設定頁靠它判斷要不要重啟。
        UITranslator.runningSelection = settings.builtinLanguage.map { .builtin($0) } ?? .system
        if let language = settings.uiTranslationLanguage {
            if translationStore.installOverride(language: language) {
                UITranslator.runningSelection = .translated(language)
                ChorusLog.app.notice("介面翻譯覆蓋已掛上：\(language)")
            } else {
                ChorusLog.app.notice("介面翻譯 \(language) 的檔不在，退回內建語言")
            }
        }
        // 實際生效的介面語言：內建語言選了什麼靠 AppleLanguages，Foundation 早在
        // 這行之前就決定完了，log 出來才有辦法對照使用者選的是什麼。
        ChorusLog.app.notice(
            "介面語言：\(Bundle.main.preferredLocalizations.first ?? "?")"
                + "（選定 \(settings.uiTranslationLanguage ?? settings.builtinLanguage ?? "跟隨系統")）"
        )
        timeline.mark("translationOverride")
        displayManager = DisplayManager(settings: settings)
        timeline.mark("displayManager")
        audioManager = AudioDeviceManager(settings: settings, displayManager: displayManager)
        timeline.mark("audioManager")
        pairedPeers = PairedPeersStore(
            defaults: instance.defaults,
            keychain: KeychainStore(service: instance.keychainService)
        )
        sessionManager = SyncSessionManager(instance: instance, pairedPeers: pairedPeers)
        timeline.mark("pairedPeers+sync")
        pairing = PairingController(instance: instance, pairedPeers: pairedPeers, sessionManager: sessionManager)
        coordinator = ControlCoordinator(
            localPeerID: instance.peerID,
            settings: settings,
            sessionManager: sessionManager,
            displayManager: displayManager,
            audioManager: audioManager
        )
        timeline.mark("coordinator")
        let sensor = AmbientLightSensorClient(fakeALS: instance.fakeALS, disabled: instance.disableALS)
        location = LocationProvider(settings: settings)
        autoBrightness = AutoBrightnessController(
            localPeerID: instance.peerID,
            settings: settings,
            displayManager: displayManager,
            sensor: sensor,
            location: location
        )
        timeline.mark("ambient")
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

        timeline.mark("advisor")
        // 能力（含 "als"）要在 sessionManager.start() 之前設定，Bonjour TXT 與 hello 才帶得到
        var capabilities = ["display", "audio", "displayModes.v1"]
        if sensor.isAvailable { capabilities.append("als") }
        // HDR 寫入未驗證前不宣告 displayHDR.v1；狀態仍可在本機 UI 顯示
        sessionManager.localCapabilities = capabilities
        pairing.localCapabilities = capabilities

        mediaKeys = MediaKeyInterceptor(
            settings: settings,
            displayManager: displayManager,
            audioManager: audioManager
        )
        windowManager = WindowManager(settings: settings)

        timeline.mark("mediaKeys")
        virtualDriver = VirtualAudioDriverController()
        audioManager.virtualDriver = virtualDriver

        keepAwake = KeepAwakeController(settings: settings, displayManager: displayManager)
        emergencyRestore = EmergencyRestoreMonitor(displayManager: displayManager)
        displayConfiguration = DisplayConfigurationController(displayManager: displayManager)

        timeline.mark("keepAwake")
        displayManager.autoController = autoBrightness
        displayManager.audioManager = audioManager
        displayManager.statusReadout = statusReadout
        audioManager.statusReadout = statusReadout
        displayManager.keepAwake = keepAwake
        displayManager.emergencyRestore = emergencyRestore
        displayManager.configurationController = displayConfiguration
        displayConfiguration.attach(displayManager: displayManager)
        AppStateRegistry.keepAwake = keepAwake
        coordinator.attachAutoController(autoBrightness)
        coordinator.attachKeepAwake(keepAwake)

        timeline.mark("wiring")
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
        timeline.mark("tapEngine")
        autoEq = AutoEqCatalog(instance: instance)
        timeline.mark("autoEq")
        alertVolume = AlertVolumeController()
        audioManager.tapEngine = tapEngine
        tapEngine.stateChangedHandler = { [weak audioManager] in
            audioManager?.refreshBridges()
        }
        timeline.mark("alertVolume")
        coordinator.tapEngine = tapEngine
        // 與光環境顧問共用同一份引擎 registry（設定頁只有一組引擎選擇）
        audioTuner = AudioTuningAdvisor(
            settings: settings,
            registry: advisor.registry,
            tapEngine: tapEngine,
            audioManager: audioManager,
            catalog: auCatalog
        )
        timeline.mark("audioTuner")
        uiTranslator = UITranslator(
            store: translationStore, settings: settings, registry: advisor.registry,
            languageDefaults: UITranslator.languageDefaults(
                instance: instance, environment: ProcessInfo.processInfo.environment
            )
        )

        timeline.mark("uiTranslator")
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
            scenes: sceneStore,
            displayConfiguration: displayConfiguration
        )

        timeline.mark("automation")
        focus = FocusSessionController(settings: settings, executor: automation, scenes: sceneStore)
        AppStateRegistry.focus = focus
        automation.focus = focus
        focusNotifier = FocusNotifier()
        focus.notifier = focusNotifier
        // peer 連上就補送欠它的跨機還原（B7-4）
        coordinator.peerConnectedHandler = { _ in
            MainActor.assumeIsolated { AppStateRegistry.focus?.retryPendingRestores() }
        }

        timeline.mark("focus")
        cloudBackup = CloudBackup(
            files: CloudBackupFiles(
                // `--cloud-root` 是 E2E 的覆寫：同機雙實例不該把東西寫進
                // 使用者真的 iCloud Drive
                location: instance.cloudRoot.map { .fixed(URL(fileURLWithPath: $0)) } ?? .iCloudDrive,
                deviceName: instance.deviceDisplayName,
                deviceID: instance.peerID
            ),
            settings: settings,
            scenes: sceneStore
        )
        AppStateRegistry.cloudBackup = cloudBackup

        timeline.mark("cloudBackup")
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

        timeline.mark("automationServer")
        // 綁定型模式跨重啟保留：螢幕 > App > Agent > 負載
        keepAwake.restoreSavedMode()

        timeline.mark("keepAwakeRestore")
        displayManager.start()
        timeline.mark("display.start")
        audioManager.start()
        timeline.mark("audio.start")
        sessionManager.start()
        timeline.mark("sync.start")
        autoBrightness.start()
        timeline.mark("ambient.start")
        mediaKeys.updateActivation()
        timeline.mark("mediaKeys.start")
        windowManager.updateActivation()
        timeline.mark("windowManager.start")
        virtualDriver.refreshStatus()
        timeline.mark("virtualDriver.refresh")
        automationServer.updateActivation()
        timeline.mark("automationServer.start")
        tapEngine.start()
        timeline.mark("taps.start")
        // 上次沒正常結束時把限時場景接回來。**要等列舉完**——顯示器與音訊
        // 裝置還沒到齊時還原會誤判「裝置已不在」，所以是延後的，不在這裡直接跑
        focus.scheduleResume()
        timeline.mark("focus.resume")
        cloudBackup.updateActivation()
        timeline.mark("cloudBackup.start")

        timeline.finish()
        let info = Bundle.main.infoDictionary
        ChorusLog.app.notice(
            "啟動 \(info?["CFBundleShortVersionString"] ?? "?") (build \(info?["CFBundleVersion"] ?? "?")) "
            + "instance=\(instance.name ?? "default") macOS \(ProcessInfo.processInfo.operatingSystemVersionString) "
            + "log=\(DiagnosticLog.shared.fileURL.path)"
        )
    }
}
