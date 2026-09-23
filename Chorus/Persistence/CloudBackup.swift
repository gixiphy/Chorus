import AppKit
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
///
/// **主執行緒不等 iCloud Drive**：所有檔案操作交給 `BackupIOWorker`，每件都有期限。
/// 寫入同時只有一件在跑、只留最新一份待寫；逾時就標「稍後重試」並退避，
/// 不在卡住的那件後面疊工作。結束 App 時不寫——設定本身在 UserDefaults，
/// 下次啟動自動備份的第一拍會補上。
@MainActor
@Observable
final class CloudBackup {
    enum Availability: Equatable {
        /// iCloud Drive 還沒探測完（探測在 worker 上做，初始化不碰檔案）。
        case checking
        case available
        case unavailable
    }

    enum Status: Equatable {
        case idle
        case working(String)
        case ok(String)
        /// iCloud Drive 沒在期限內回應。設定仍在本機，稍後自動重試。
        case deferred(String)
        case failed(String)
    }

    struct Timing: Sendable {
        var writeDeadline: Duration = .seconds(15)
        var readDeadline: Duration = .seconds(15)
        /// 自動備份檢查間隔。拖 EQ 滑桿時每半秒寫一次 iCloud Drive 只是浪費，
        /// 而設定晚一分鐘上去沒有任何差別。
        var tickInterval: Duration = .seconds(60)
        /// 逾時後的重試退避（等卡住的那件做完之後才開始算）。
        var retryBase: Duration = .seconds(5)
        var retryMax: Duration = .seconds(120)
    }

    private(set) var availability: Availability
    private(set) var status: Status = .idle
    /// `devices/` 底下有哪些機器（含這台）。
    private(set) var files: [BackupFile] = []
    private(set) var lastBackupDate: Date?

    let displayPath: String
    let deviceName: String
    @ObservationIgnored private let deviceID: String

    @ObservationIgnored private let worker: BackupIOWorker
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private unowned let scenes: SceneStore
    @ObservationIgnored private let timing: Timing
    @ObservationIgnored private let pressure: MemoryPressureMonitor
    /// 自動備份正因記憶體壓力暫停中（只在進出時各寫一行紀錄）。
    @ObservationIgnored private var deferredByPressure = false

    private struct Revision {
        let number: Int
        let backup: DeviceBackup
    }

    /// 上一次確實寫出去的內容。**沒變就不寫**——iCloud Drive 上的檔案每寫一次
    /// 都會觸發一輪同步，而設定多數時間是不動的。
    @ObservationIgnored private var lastWritten: DeviceBackup?
    /// 還沒寫出去的最新一份。中間版本沒有保留價值，只留最新。
    @ObservationIgnored private var pending: Revision?
    /// 正在 worker 上寫的那一份。
    @ObservationIgnored private var writing: Revision?
    @ObservationIgnored private var nextRevision = 0
    @ObservationIgnored private var waiters: [(revision: Int, continuation: CheckedContinuation<Bool, Never>)] = []
    @ObservationIgnored private var drainTask: Task<Void, Never>?
    /// 上一件寫入逾時、正在等 worker 空下來。這段期間新的要求只更新待寫內容，
    /// 立刻回報「稍後重試」，不陪著卡住的那件一起等。
    @ObservationIgnored private var awaitingRecovery = false
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var probeTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private static let log = ChorusLog(category: "backup")

    init(
        files: CloudBackupFiles,
        settings: SettingsStore,
        scenes: SceneStore,
        timing: Timing = Timing(),
        pressure: MemoryPressureMonitor = .shared
    ) {
        worker = BackupIOWorker(files: files)
        self.pressure = pressure
        self.settings = settings
        self.scenes = scenes
        self.timing = timing
        deviceName = files.deviceName
        deviceID = files.deviceID
        displayPath = files.displayPath
        availability = switch files.location {
        case let .fixed(url): url == nil ? .unavailable : .available
        case .iCloudDrive: .checking
        }
    }

    var isAvailable: Bool { availability == .available }

    // MARK: - 快照與套用

    /// 目前的設定 → 一份備份。
    func snapshot() -> DeviceBackup {
        DeviceBackup(
            savedAt: .now,
            deviceName: deviceName,
            deviceID: deviceID,
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
            displayModePreferences: Array(settings.displayModePreferences.values),
            autoBrightnessEnabled: settings.autoBrightnessEnabled,
            ambientCurve: settings.ambientCurve,
            ambientDisplayOffsets: settings.ambientDisplayOffsets,
            ambientDeviceOffset: settings.ambientDeviceOffset,
            ambientExcludedDisplays: Array(settings.ambientExcludedDisplays),
            ambientScheduleEnabled: settings.ambientScheduleEnabled,
            ambientSchedule: settings.ambientSchedule,
            keepAwakePreventsSystemSleep: settings.keepAwakePreventsSystemSleep,
            keepAwakeDisplayUUID: settings.keepAwakeDisplayUUID,
            keepAwakeAppBundleID: settings.keepAwakeAppBundleID,
            keepAwakeAgentMode: settings.keepAwakeAgentMode,
            keepAwakeSystemLoadMode: settings.keepAwakeSystemLoadMode,
            keepAwakeSystemLoadConfiguration: settings.keepAwakeSystemLoadConfiguration,
            keepAwakeProcessDetection: settings.keepAwakeProcessDetection,
            keepAwakeCustomProcessNames: settings.keepAwakeCustomProcessNames,
            mediaKeyCaptureEnabled: settings.mediaKeyCaptureEnabled,
            syncBrightnessEnabled: settings.syncBrightnessEnabled,
            syncVolumeEnabled: settings.syncVolumeEnabled,
            advisorEngineID: settings.advisorEngineID,
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
        if let prefs = backup.displayModePreferences {
            settings.displayModePreferences = Dictionary(
                uniqueKeysWithValues: prefs.map { ($0.displayUUID, $0) }
            )
        }
        settings.autoBrightnessEnabled = backup.autoBrightnessEnabled
        settings.ambientCurve = backup.ambientCurve
        settings.ambientDisplayOffsets = backup.ambientDisplayOffsets
        settings.ambientDeviceOffset = backup.ambientDeviceOffset
        settings.ambientExcludedDisplays = Set(backup.ambientExcludedDisplays)
        settings.ambientScheduleEnabled = backup.ambientScheduleEnabled
        settings.ambientSchedule = backup.ambientSchedule
        settings.keepAwakePreventsSystemSleep = backup.keepAwakePreventsSystemSleep
        settings.keepAwakeDisplayUUID = backup.keepAwakeDisplayUUID
        settings.keepAwakeAppBundleID = backup.keepAwakeAppBundleID
        settings.keepAwakeAgentMode = backup.keepAwakeAgentMode
        settings.keepAwakeSystemLoadMode = backup.keepAwakeSystemLoadMode
        settings.keepAwakeSystemLoadConfiguration = backup.keepAwakeSystemLoadConfiguration
        settings.keepAwakeProcessDetection = backup.keepAwakeProcessDetection
        settings.keepAwakeCustomProcessNames = backup.keepAwakeCustomProcessNames
        settings.mediaKeyCaptureEnabled = backup.mediaKeyCaptureEnabled
        settings.syncBrightnessEnabled = backup.syncBrightnessEnabled
        settings.syncVolumeEnabled = backup.syncVolumeEnabled
        settings.advisorEngineID = backup.advisorEngineID
        settings.advisorDisabledEngines = Set(backup.advisorDisabledEngines)
        settings.advisorCustomPaths = backup.advisorCustomPaths
        settings.automationServerEnabled = backup.automationServerEnabled
        settings.automationServerPort = backup.automationServerPort
        settings.focusLastDuration = backup.focusLastDuration
        settings.focusNotifyOnEnd = backup.focusNotifyOnEnd
        settings.cloudBackupEnabled = backup.cloudBackupEnabled
    }

    // MARK: - 備份

    /// 立即備份。回傳**這一版**有沒有確實寫進 iCloud Drive 資料夾——寫進資料夾
    /// 不等於 Apple 伺服器已經收到。逾時回 false，但那一版仍留著、稍後自動重試。
    @discardableResult
    func backupNow() async -> Bool {
        guard await ensureAvailability() else { return false }
        let revision = enqueue(snapshot())
        if awaitingRecovery { return false }
        return await withCheckedContinuation { continuation in
            waiters.append((revision, continuation))
        }
    }

    /// 自動備份的一拍。**內容沒變就不寫**；等這一輪寫完才返回。
    /// 記憶體壓力 critical 時整拍跳過（手動「立即備份」不受影響）。
    func tick() async {
        guard settings.cloudBackupEnabled else { return }
        guard !pressure.blocksHeavyWork else {
            if !deferredByPressure {
                deferredByPressure = true
                Self.log.notice("記憶體壓力 critical：自動備份暫停，恢復後下一拍補上")
            }
            return
        }
        deferredByPressure = false
        guard await ensureAvailability() else { return }
        let current = snapshot()
        let known = [lastWritten, writing?.backup, pending?.backup].compactMap { $0 }
        if let newest = known.last, newest.hasSameContent(as: current) {
            await drainTask?.value
            return
        }
        _ = enqueue(current)
        await drainTask?.value
    }

    /// 開關切換或啟動時呼叫。開著就起一個節流計時器。
    func updateActivation() {
        tickTask?.cancel()
        tickTask = nil
        guard settings.cloudBackupEnabled else { return }
        let interval = timing.tickInterval
        tickTask = Task { [weak self] in
            // 開啟的當下先寫一次，使用者才看得到東西出現在 Finder 裡
            await self?.tick()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                await self.tick()
            }
        }
    }

    /// App 要結束了。**不碰 iCloud Drive**：CloudDocs 卡住時，結束會跟著卡。
    /// 還沒寫出去的變更不會丟——設定本身在 UserDefaults，下次啟動自動備份的
    /// 第一拍（這時 `lastWritten` 是空的）就會寫出目前的內容。
    func shutdown() {
        tickTask?.cancel()
        tickTask = nil
        drainTask?.cancel()
        drainTask = nil
        awaitingRecovery = false
        pending = nil
        resolveWaiters(through: .max, succeeded: false)
    }

    private func enqueue(_ backup: DeviceBackup) -> Int {
        nextRevision += 1
        pending = Revision(number: nextRevision, backup: backup)
        if drainTask == nil {
            drainTask = Task { [weak self] in await self?.drain() }
        }
        return nextRevision
    }

    /// 一次寫一份：寫完再看有沒有更新的待寫。只有這裡會發起寫入。
    private func drain() async {
        var retryDelay = timing.retryBase
        while let job = pending, !Task.isCancelled {
            pending = nil
            writing = job
            status = .working(String(localized: "正在備份…"))
            let outcome = await worker.run(deadline: timing.writeDeadline) { files -> Date? in
                try files.write(job.backup)
                return files.lastBackupDate
            }
            writing = nil
            guard !Task.isCancelled else { break }
            switch outcome {
            case let .completed(.success(date)):
                retryDelay = timing.retryBase
                lastWritten = job.backup
                lastBackupDate = date
                // 不帶時間戳：「上次備份」那一列已經在講同一件事，兩行重複只是
                // 讓使用者多讀一次（截圖驗證時發現的）
                status = .ok(String(localized: "已備份"))
                resolveWaiters(through: job.number, succeeded: true)
                if pending == nil { await refresh() }
            case let .completed(.failure(error)):
                status = .failed(String(localized: "備份失敗：\(error.localizedDescription)"))
                Self.log.error("備份寫入失敗：\(error.localizedDescription)")
                resolveWaiters(through: job.number, succeeded: false)
            case .timedOut, .busy:
                // 這一版留著重試；期間有更新的版本進來，就讓位給新的
                if pending == nil { pending = job }
                status = .deferred(String(localized: "iCloud Drive 沒有回應，設定已存在本機，稍後重試"))
                Self.log.notice("備份寫入沒有在期限內完成，\(OperationMetrics.format(retryDelay)) 後重試")
                resolveWaiters(through: job.number, succeeded: false)
                // 等卡住的那件真的做完，才排下一次——不在它後面疊工作
                awaitingRecovery = true
                let poll = min(retryDelay, .seconds(1))
                while !worker.isIdle, !Task.isCancelled {
                    try? await Task.sleep(for: poll)
                }
                try? await Task.sleep(for: retryDelay)
                awaitingRecovery = false
                retryDelay = min(retryDelay * 2, timing.retryMax)
            }
        }
        if !Task.isCancelled { drainTask = nil }
    }

    private func resolveWaiters(through revision: Int, succeeded: Bool) {
        let ready = waiters.filter { $0.revision <= revision }
        waiters.removeAll { $0.revision <= revision }
        for waiter in ready {
            waiter.continuation.resume(returning: succeeded)
        }
    }

    // MARK: - 探測

    /// iCloud Drive 開了沒有。探測逾時就維持 `.checking`，下次再試。
    private func ensureAvailability() async -> Bool {
        if availability == .checking {
            if probeTask == nil {
                probeTask = Task { [weak self] in
                    guard let self else { return }
                    let outcome = await worker.run(deadline: timing.readDeadline) { $0.probeAvailability() }
                    if case let .completed(.success(available)) = outcome {
                        availability = available ? .available : .unavailable
                    }
                    probeTask = nil
                }
            }
            await probeTask?.value
        }
        switch availability {
        case .available:
            return true
        case .unavailable:
            status = .failed(String(localized: "iCloud Drive 未啟用"))
            return false
        case .checking:
            status = .deferred(String(localized: "iCloud Drive 沒有回應，稍後再試"))
            return false
        }
    }

    // MARK: - 匯入

    /// 匯入某一台的備份。
    ///
    /// **匯入前先把這台現況另存一份退路**（`-before-import`）：這個動作會蓋掉
    /// 目前的設定，而使用者按下去的那一刻多半沒想清楚這件事。讀取與退路都在
    /// worker 上做完、確認讀得到，才回主執行緒套用。
    @discardableResult
    func importBackup(_ file: BackupFile) async -> Bool {
        let local = snapshot()
        let url = file.url
        let outcome = await worker.run(deadline: timing.readDeadline) { files -> DeviceBackup? in
            guard let incoming = files.decode(at: url) else { return nil }
            if let devices = files.devicesDirectory {
                let escape = devices.appending(path: "\(local.deviceName)-before-import.json")
                _ = try? files.write(local, to: escape)
            }
            return incoming
        }
        let incoming: DeviceBackup
        switch outcome {
        case let .completed(.success(decoded?)):
            incoming = decoded
        case .completed:
            status = .failed(String(localized: "讀取「\(file.deviceName)」的設定失敗"))
            return false
        case .timedOut, .busy:
            status = .deferred(String(localized: "iCloud Drive 沒有回應，沒有匯入任何設定"))
            return false
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
        await refresh()
        return true
    }

    /// 重新掃描 `devices/`。同時只有一輪；逾時就保留上次的清單。
    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self, await ensureAvailability() else { return }
            let outcome = await worker.run(deadline: timing.readDeadline) { files in
                (files.scan(), files.lastBackupDate)
            }
            if case let .completed(.success((scanned, date))) = outcome {
                files = scanned
                lastBackupDate = date
            }
        }
        refreshTask = task
        await task.value
        refreshTask = nil
    }

    func revealInFinder() {
        Task {
            let outcome = await worker.run(deadline: timing.readDeadline) { $0.revealTarget() }
            guard case let .completed(.success(target?)) = outcome else { return }
            if target.selectsItem {
                NSWorkspace.shared.activateFileViewerSelecting([target.url])
            } else {
                NSWorkspace.shared.open(target.url)
            }
        }
    }
}
