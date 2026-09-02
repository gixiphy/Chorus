import ChorusCore
import Foundation
import Observation
import OSLog

/// 設定備份到 iCloud Drive（B8）。
///
/// **只寫不讀**：這台的真相在 UserDefaults，iCloud 上那份是備份。沒有任何
/// 自動讀回的路徑——每次啟動拿備份回頭套本機，只會多一條「拿舊資料蓋新資料」
/// 的路，而它換來的好處（換新 Mac 時接手）本來就要人工介入。匯入是設定頁上
/// 的一個按鈕。
///
/// 因此這裡**不是同步**：別台的設定不會自己跑過來。使用者第一次看到「同步」
/// 兩個字會預期「全部一樣」，所以 UI 從頭到尾不用那個詞。
@MainActor
@Observable
final class CloudBackup {
    enum Status: Equatable {
        case idle
        case ok(String)
        case failed(String)
    }

    private(set) var status: Status = .idle
    /// `devices/` 底下有哪些機器（含這台）。
    private(set) var files: [BackupFile] = []
    private(set) var lastBackupDate: Date?

    @ObservationIgnored private let files_: CloudBackupFiles
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private unowned let scenes: SceneStore
    /// 上一次寫出去的內容。**沒變就不寫**——iCloud Drive 上的檔案每寫一次
    /// 都會觸發一輪同步，而設定多數時間是不動的。
    @ObservationIgnored private var lastWritten: DeviceBackup?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private static let log = ChorusLog(category: "backup")

    init(files: CloudBackupFiles, settings: SettingsStore, scenes: SceneStore) {
        files_ = files
        self.settings = settings
        self.scenes = scenes
        lastBackupDate = files.lastBackupDate
    }

    var isAvailable: Bool { files_.isAvailable }
    var displayPath: String { files_.displayPath }
    var deviceName: String { files_.deviceName }

    // MARK: - 快照與套用

    /// 目前的設定 → 一份備份。
    func snapshot() -> DeviceBackup {
        DeviceBackup(
            savedAt: .now,
            deviceName: files_.deviceName,
            deviceID: files_.deviceID,
            scenes: scenes.scenes,
            deviceEQ: settings.deviceEQ,
            deviceBalance: settings.deviceBalance,
            deviceEffects: settings.deviceEffects,
            appAudio: settings.appAudio,
            excludedApps: Array(settings.excludedApps),
            excludedDevices: Array(settings.excludedDevices),
            softwareVolumeDevices: Array(settings.softwareVolumeDevices),
            outputPriority: settings.outputPriority,
            hiddenAudioDevices: Array(settings.hiddenAudioDevices),
            audioBridgeDisabled: Array(settings.audioBridgeDisabled),
            virtualTargetUID: settings.virtualTargetUID,
            effectQuarantine: Array(settings.effectQuarantine),
            audioTapsEnabled: settings.audioTapsEnabled,
            forceSoftwareDimming: Array(settings.forceSoftwareDimming),
            subZeroDimming: Array(settings.subZeroDimming),
            disableDDCRead: Array(settings.disableDDCRead),
            autoBrightnessEnabled: settings.autoBrightnessEnabled,
            ambientCurve: settings.ambientCurve,
            ambientDisplayOffsets: settings.ambientDisplayOffsets,
            ambientDeviceOffset: settings.ambientDeviceOffset,
            ambientExcludedDisplays: Array(settings.ambientExcludedDisplays),
            keepAwakePreventsSystemSleep: settings.keepAwakePreventsSystemSleep,
            keepAwakeDisplayUUID: settings.keepAwakeDisplayUUID,
            keepAwakeAppBundleID: settings.keepAwakeAppBundleID,
            mediaKeyCaptureEnabled: settings.mediaKeyCaptureEnabled,
            syncBrightnessEnabled: settings.syncBrightnessEnabled,
            syncVolumeEnabled: settings.syncVolumeEnabled,
            advisorEngineID: settings.advisorEngineID,
            advisorModelIDs: settings.advisorModelIDs,
            advisorDisabledEngines: Array(settings.advisorDisabledEngines),
            advisorCustomPaths: settings.advisorCustomPaths,
            automationServerEnabled: settings.automationServerEnabled,
            automationServerPort: settings.automationServerPort,
            focusLastDuration: settings.focusLastDuration,
            focusNotifyOnEnd: settings.focusNotifyOnEnd,
            cloudBackupEnabled: settings.cloudBackupEnabled
        )
    }

    /// 套用一份備份。**寫進 store，不直接碰任何 manager**——既有的
    /// `@Observable` 鏈會讓 EQ 引擎、選單列與自動亮度自己跟上，
    /// 走的是與手動改設定完全同一條路。
    func apply(_ backup: DeviceBackup) {
        scenes.replaceAll(backup.scenes)
        settings.deviceEQ = backup.deviceEQ
        settings.deviceBalance = backup.deviceBalance
        settings.deviceEffects = backup.deviceEffects
        settings.appAudio = backup.appAudio
        settings.excludedApps = Set(backup.excludedApps)
        settings.excludedDevices = Set(backup.excludedDevices)
        settings.softwareVolumeDevices = Set(backup.softwareVolumeDevices)
        settings.outputPriority = backup.outputPriority
        settings.hiddenAudioDevices = Set(backup.hiddenAudioDevices)
        settings.audioBridgeDisabled = Set(backup.audioBridgeDisabled)
        settings.virtualTargetUID = backup.virtualTargetUID
        settings.effectQuarantine = Set(backup.effectQuarantine)
        settings.audioTapsEnabled = backup.audioTapsEnabled
        settings.forceSoftwareDimming = Set(backup.forceSoftwareDimming)
        settings.subZeroDimming = Set(backup.subZeroDimming)
        settings.disableDDCRead = Set(backup.disableDDCRead)
        settings.autoBrightnessEnabled = backup.autoBrightnessEnabled
        settings.ambientCurve = backup.ambientCurve
        settings.ambientDisplayOffsets = backup.ambientDisplayOffsets
        settings.ambientDeviceOffset = backup.ambientDeviceOffset
        settings.ambientExcludedDisplays = Set(backup.ambientExcludedDisplays)
        settings.keepAwakePreventsSystemSleep = backup.keepAwakePreventsSystemSleep
        settings.keepAwakeDisplayUUID = backup.keepAwakeDisplayUUID
        settings.keepAwakeAppBundleID = backup.keepAwakeAppBundleID
        settings.mediaKeyCaptureEnabled = backup.mediaKeyCaptureEnabled
        settings.syncBrightnessEnabled = backup.syncBrightnessEnabled
        settings.syncVolumeEnabled = backup.syncVolumeEnabled
        settings.advisorEngineID = backup.advisorEngineID
        settings.advisorModelIDs = backup.advisorModelIDs
        settings.advisorDisabledEngines = Set(backup.advisorDisabledEngines)
        settings.advisorCustomPaths = backup.advisorCustomPaths
        settings.automationServerEnabled = backup.automationServerEnabled
        settings.automationServerPort = backup.automationServerPort
        settings.focusLastDuration = backup.focusLastDuration
        settings.focusNotifyOnEnd = backup.focusNotifyOnEnd
        settings.cloudBackupEnabled = backup.cloudBackupEnabled
    }

    // MARK: - 備份

    @discardableResult
    func backupNow() -> Bool {
        guard isAvailable else {
            status = .failed(String(localized: "iCloud Drive 未啟用"))
            return false
        }
        let backup = snapshot()
        do {
            try files_.write(backup)
            lastWritten = backup
            lastBackupDate = files_.lastBackupDate
            // 不帶時間戳：「上次備份」那一列已經在講同一件事，兩行重複只是
            // 讓使用者多讀一次（截圖驗證時發現的）
            status = .ok(String(localized: "已備份"))
            refresh()
            return true
        } catch {
            status = .failed(String(localized: "備份失敗：\(error.localizedDescription)"))
            Self.log.error("備份寫入失敗：\(error.localizedDescription)")
            return false
        }
    }

    /// 自動備份的一拍。**內容沒變就不寫**。
    func tick() {
        guard settings.cloudBackupEnabled, isAvailable else { return }
        let current = snapshot()
        if let lastWritten, lastWritten.hasSameContent(as: current) { return }
        backupNow()
    }

    /// 開關切換或啟動時呼叫。開著就起一個節流計時器。
    ///
    /// 60 秒一拍而不是「每次變更立刻寫」：拖 EQ 滑桿時每半秒寫一次
    /// iCloud Drive 只是浪費，而設定晚一分鐘上去沒有任何差別。
    func updateActivation() {
        tickTask?.cancel()
        tickTask = nil
        guard settings.cloudBackupEnabled, isAvailable else { return }
        // 開啟的當下先寫一次，使用者才看得到東西出現在 Finder 裡
        tick()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.tick()
            }
        }
    }

    /// App 要結束了：把還沒寫出去的那一分鐘補上。
    func shutdown() {
        tickTask?.cancel()
        tickTask = nil
        tick()
    }

    // MARK: - 匯入

    /// 匯入某一台的備份。
    ///
    /// **匯入前先把這台現況另存一份退路**（`-before-import`）：這個動作會蓋掉
    /// 目前的設定，而使用者按下去的那一刻多半沒想清楚這件事。
    @discardableResult
    func importBackup(_ file: BackupFile) -> Bool {
        guard let incoming = files_.decode(at: file.url) else {
            status = .failed(String(localized: "讀取「\(file.deviceName)」的設定失敗"))
            return false
        }
        let local = snapshot()
        if let devices = files_.devicesDirectory {
            let escape = devices.appending(path: "\(local.deviceName)-before-import.json")
            try? files_.write(local, to: escape)
        }

        // 同一台（重灌後）：全套。綁機的鍵正是最想要回來的東西。
        // 別台：綁機與權限鍵保留本機的（見 BackupPortability）。
        let resolved = file.isSelf ? incoming : incoming.portableMerged(onto: local)
        apply(resolved)
        lastWritten = nil // 內容變了，下一拍要重新寫出去

        let skipped = file.isSelf ? 0 : BackupPortability.machineBound.count
        status = .ok(file.isSelf
            ? String(localized: "已從「\(file.deviceName)」還原全部設定")
            : String(localized: "已從「\(file.deviceName)」匯入，跳過 \(skipped) 項綁機設定"))
        refresh()
        return true
    }

    func refresh() {
        files = files_.scan()
        lastBackupDate = files_.lastBackupDate
    }

    func revealInFinder() { files_.revealInFinder() }

}
