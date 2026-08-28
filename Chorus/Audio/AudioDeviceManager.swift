import AppKit
import ChorusCore
import CoreAudio
import Foundation
import Observation

/// 輸出裝置清單與音量/mute/預設裝置控制的入口（MainActor）。
/// 實際 CoreAudio IO 在 AudioWorker 的 serial queue 上。
@MainActor
@Observable
final class AudioDeviceManager {
    private(set) var devices: [AudioDeviceModel] = []

    @ObservationIgnored private let worker = AudioWorker()
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private weak var displayManager: DisplayManager?
    /// BV 虛擬輸出裝置控制器（音量鏡射與模式切換用）。
    @ObservationIgnored weak var virtualDriver: VirtualAudioDriverController?
    @ObservationIgnored private var consumeTask: Task<Void, Never>?
    @ObservationIgnored weak var coordinator: ControlCoordinator?
    /// 逐 App 路由（B6-3）要知道裝置清單何時變動——指定的目標裝置
    /// 插回來時 session 要接回去。
    @ObservationIgnored weak var tapEngine: TapEngine?

    /// 我們自己剛寫入的值：snapshot 回報若與其相近則不覆蓋 UI（避免拖曳中跳動）。
    @ObservationIgnored private var recentLocalSets: [String: (value: Double, at: ContinuousClock.Instant)] = [:]
    /// DDC 音量寫後驗證任務（每裝置一個，拖曳中重排程）。
    @ObservationIgnored private var bridgeVerifyTasks: [String: Task<Void, Never>] = [:]
    /// A/B 旁通用的暫時 EQ（不持久化，見 `setEQOverride`）。
    @ObservationIgnored private var eqOverrides: [String: EQSettings] = [:]
    /// 上一輪 snapshot 看到的裝置。**優先權切換只在這一份變動時觸發**——
    /// 每個 snapshot 都搶預設裝置會讓使用者根本選不動別的裝置。
    @ObservationIgnored private var knownUIDs: Set<String> = []

    var defaultDevice: AudioDeviceModel? {
        devices.first(where: \.isDefault)
    }

    /// BV 虛擬輸出裝置本身（未安裝／未載入時為 nil）。
    var virtualDevice: AudioDeviceModel? {
        devices.first { $0.uid == VirtualAudioDriverController.deviceUID }
    }

    /// 虛擬裝置目前轉送到的實體裝置。選單把兩者併成**一列**——
    /// 「Chorus Screen Output」與它背後的螢幕是同一個輸出的兩個面向，
    /// 分開列會讓使用者以為有兩個可選的目的地（選錯那個就沒有音量鍵）。
    var virtualForwardTarget: AudioDeviceModel? {
        guard virtualDevice != nil, let uid = virtualDriver?.targetUID else { return nil }
        return devices.first { $0.uid == uid }
    }

    /// 選單可以列出的裝置：併進虛擬裝置那一列的轉送目標不單獨出現
    /// （連「顯示隱藏裝置」展開後也不出現——它不是被隱藏，是被合併）。
    var listableDevices: [AudioDeviceModel] {
        let merged = virtualForwardTarget?.uid
        return devices.filter { $0.uid != merged }
    }

    /// 選單列顯示的裝置：排除使用者隱藏的；預設輸出永遠顯示（避免被劫走
    /// 預設卻看不到是誰——被合併的轉送目標例外，虛擬裝置那一列會講）。
    var visibleDevices: [AudioDeviceModel] {
        listableDevices.filter { !settings.hiddenAudioDevices.contains($0.uid) || $0.isDefault }
    }

    /// 選單上顯示的名稱：虛擬裝置那一列掛的是轉送目標的名字
    /// （使用者要選的是「那台螢幕」，「Chorus Screen Output」只是管路）。
    func displayName(for device: AudioDeviceModel) -> String {
        guard device.uid == VirtualAudioDriverController.deviceUID else { return device.name }
        return virtualForwardTarget?.name ?? device.name
    }

    func setHidden(_ hidden: Bool, for device: AudioDeviceModel) {
        var set = settings.hiddenAudioDevices
        if hidden { set.insert(device.uid) } else { set.remove(device.uid) }
        settings.hiddenAudioDevices = set
    }

    func isHidden(_ device: AudioDeviceModel) -> Bool {
        settings.hiddenAudioDevices.contains(device.uid)
    }

    /// 標記／取消「此螢幕不支援 DDC 音量」（右鍵選單）。
    func setBridgeDisabled(_ disabled: Bool, for device: AudioDeviceModel) {
        var set = settings.audioBridgeDisabled
        if disabled { set.insert(device.uid) } else { set.remove(device.uid) }
        settings.audioBridgeDisabled = set
        device.bridgeUnresponsive = false
        refreshBridges()
    }

    func isBridgeDisabled(_ device: AudioDeviceModel) -> Bool {
        settings.audioBridgeDisabled.contains(device.uid)
    }

    // MARK: - 軟體音量（三後端矩陣第三條，B6-4）

    /// 這個裝置有沒有資格用軟體音量：**前兩條後端都走不通**才輪到它
    /// （DESIGN §5 的互斥規則——同一裝置同一時間只有一個後端生效）。
    func canUseSoftwareVolume(_ device: AudioDeviceModel) -> Bool {
        !device.canSetVolume && device.bridgedDisplayID == nil
    }

    func isSoftwareVolumeEnabled(_ device: AudioDeviceModel) -> Bool {
        settings.softwareVolumeDevices.contains(device.uid)
    }

    func setSoftwareVolumeEnabled(_ enabled: Bool, for device: AudioDeviceModel) {
        var set = settings.softwareVolumeDevices
        if enabled { set.insert(device.uid) } else { set.remove(device.uid) }
        settings.softwareVolumeDevices = set
        refreshBridges()
    }

    /// 全域 tap 只抓得到「正在往預設輸出播」的音訊——它是系統混音的
    /// mixdown，不是某個裝置的匯流排。因此軟體音量只在該裝置**就是目前的
    /// 預設輸出**時才成立；不是的時候誠實說明，而不是裝作有效。
    func softwareVolumeUnavailableReason(_ device: AudioDeviceModel) -> String? {
        if !isSoftwareVolumeEnabled(device) { return nil }
        if !device.isDefault { return "軟體音量只在此裝置是預設輸出時生效" }
        switch tapEngine?.state {
        case .active: return nil
        case .denied: return "系統音訊錄製權限被拒——軟體音量無法運作"
        case .off, nil: return "需要先在設定 → 音訊開啟「App 音訊接管」"
        default: return "正在確認權限…"
        }
    }

    init(settings: SettingsStore, displayManager: DisplayManager) {
        self.settings = settings
        self.displayManager = displayManager
    }

    func start() {
        worker.start()
        // 音訊 VCP（0x62/0x8D）持續寫入失敗 → 標記橋接無回應（不影響亮度）
        displayManager?.ddc.setAudioFailureHandler { displayID in
            Task { @MainActor in
                guard let manager = AppStateRegistry.displayManager?.audioManager else { return }
                for device in manager.devices where device.bridgedDisplayID == displayID {
                    device.bridgeUnresponsive = true
                }
            }
        }
        consumeTask = Task { [weak self] in
            guard let stream = self?.worker.snapshots else { return }
            for await snapshot in stream {
                self?.apply(snapshot)
            }
        }
    }

    // MARK: - 控制

    /// 使用者透過 UI 設定音量（預設裝置會廣播同步）。value 0–1。
    func setVolume(_ value: Double, for device: AudioDeviceModel) {
        let clamped = min(max(value, 0), 1)
        writeVolume(clamped, to: device)
        if device.isDefault {
            coordinator?.localVolumeChanged(clamped)
        }
    }

    func setMuted(_ muted: Bool, for device: AudioDeviceModel) {
        writeMute(muted, to: device)
        if device.isDefault {
            coordinator?.localMuteChanged(muted)
        }
    }

    /// 遠端同步套用到預設裝置。**不**觸發廣播。
    func applySyncedVolume(_ value: Double) {
        guard let device = defaultDevice else { return }
        writeVolume(min(max(value, 0), 1), to: device)
    }

    func applySyncedMute(_ muted: Bool) {
        guard let device = defaultDevice else { return }
        writeMute(muted, to: device)
    }

    /// 遙控指定裝置（UID 不存在時 no-op）。**不**觸發廣播。
    func applyVolume(_ value: Double, toUID uid: String) {
        guard let device = devices.first(where: { $0.uid == uid }) else { return }
        writeVolume(min(max(value, 0), 1), to: device)
    }

    func applyMute(_ muted: Bool, toUID uid: String) {
        guard let device = devices.first(where: { $0.uid == uid }) else { return }
        writeMute(muted, to: device)
    }

    private func writeVolume(_ clamped: Double, to device: AudioDeviceModel) {
        device.volume = clamped
        recentLocalSets[device.uid] = (clamped, ContinuousClock.now)
        settings.setLastVolume(clamped, for: device.uid)

        if device.canSetVolume {
            worker.setVolume(device.id, to: clamped)
            if device.uid == VirtualAudioDriverController.deviceUID {
                mirrorVirtualVolume(clamped)
            }
        } else if device.softwareVolumeActive {
            pushDeviceProcessing(device)
        } else if let displayID = device.bridgedDisplayID {
            // 螢幕可能處於 DDC 靜音（0x8D）而我們不知道——調音量＝想聽到聲音，
            // 比照 macOS 語意一併送解除靜音（DDC 層的重複值去重讓它幾乎免費）
            if !device.muted {
                displayManager?.ddc.write(displayID, vcp: DDCController.VCP.mute, value: DDCController.MuteValue.unmuted)
            }
            let range = Double(Swift.max(device.bridgeVolumeMax, 1))
            displayManager?.ddc.write(displayID, vcp: DDCController.VCP.volume, value: UInt16((clamped * range).rounded()))
            scheduleBridgeVerify(device: device, displayID: displayID, expected: clamped)
        }
    }

    /// 寫後驗證：拖曳結束 1.5 秒後回讀 VCP 0x62，分辨「橋接正常」與
    /// 「螢幕不理音量指令（不支援 0x62）」——兩者在 UI 上完全看不出差別，
    /// 只有讀值能戳破。讀不到（螢幕不支援讀）視為無定論、不標記。
    private func scheduleBridgeVerify(device: AudioDeviceModel, displayID: CGDirectDisplayID, expected: Double) {
        guard let displayManager,
              let display = displayManager.displays.first(where: { $0.id == displayID }),
              !settings.disableDDCRead.contains(display.uuid) else { return }
        let uid = device.uid
        bridgeVerifyTasks[uid]?.cancel()
        bridgeVerifyTasks[uid] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self else { return }
            guard let result = await self.displayManager?.ddc.read(displayID, vcp: DDCController.VCP.volume),
                  result.max > 0 else { return }
            guard let model = self.devices.first(where: { $0.uid == uid }),
                  model.bridgedDisplayID == displayID else { return }
            let actual = Double(result.current) / Double(result.max)
            model.bridgeUnresponsive = abs(actual - expected) > 0.08
        }
    }

    private func writeMute(_ muted: Bool, to device: AudioDeviceModel) {
        device.muted = muted
        if device.hasMute {
            worker.setMute(device.id, muted: muted)
            if device.uid == VirtualAudioDriverController.deviceUID {
                mirrorVirtualMute(muted)
            }
        } else if device.softwareVolumeActive {
            pushDeviceProcessing(device)
        } else if let displayID = device.bridgedDisplayID {
            displayManager?.ddc.write(
                displayID,
                vcp: DDCController.VCP.mute,
                value: muted ? DDCController.MuteValue.muted : DDCController.MuteValue.unmuted
            )
        }
    }

    func setAsDefault(_ device: AudioDeviceModel) {
        for model in devices {
            model.isDefault = model.id == device.id
        }
        worker.setDefaultOutputDevice(device.id)
    }

    // MARK: - Snapshot 套用

    private func apply(_ snapshot: AudioWorker.Snapshot) {
        var updated: [AudioDeviceModel] = []
        for info in snapshot.devices {
            let isDefault = info.id == snapshot.defaultDeviceID
            if let existing = devices.first(where: { $0.uid == info.uid }) {
                existing.isDefault = isDefault
                // 橋接裝置（無 CoreAudio 音量）的 snapshot 值無意義（恆為 0），
                // model 由 DDC 路徑維護——不能讓任何音訊事件把滑桿蓋成 0。
                if info.canSetVolume, !shouldPreserveLocalValue(uid: info.uid, reported: info.volume) {
                    // 非本 App 寫入造成的變更（媒體鍵、Touch Bar、其他 App）
                    // → 視為本地硬體事件
                    let changed = abs(existing.volume - info.volume) > 0.005
                    existing.volume = info.volume
                    if changed {
                        // Touch Bar／控制中心動的是虛擬裝置 → 鏡射到螢幕硬體
                        if info.uid == VirtualAudioDriverController.deviceUID {
                            mirrorVirtualVolume(info.volume)
                        }
                        if isDefault {
                            coordinator?.localVolumeChanged(info.volume)
                        }
                    }
                }
                if info.hasMute, existing.muted != info.muted {
                    existing.muted = info.muted
                    if info.uid == VirtualAudioDriverController.deviceUID {
                        mirrorVirtualMute(info.muted)
                    }
                    if isDefault {
                        coordinator?.localMuteChanged(info.muted)
                    }
                }
                updated.append(existing)
            } else {
                let model = AudioDeviceModel(info: info, isDefault: isDefault)
                if !info.canSetVolume {
                    // HDMI/DP 裝置沒有軟體音量：試著橋接到 DDC 顯示器
                    model.bridgedDisplayID = bridgeTarget(forDeviceNamed: info.name)?.id
                    model.volume = settings.lastVolume(for: info.uid) ?? 0.3
                }
                if info.uid == VirtualAudioDriverController.deviceUID {
                    // 虛擬裝置剛出現（安裝完／coreaudiod 重啟）→ 讀 driver 設定
                    virtualDriver?.refreshStatus()
                }
                updated.append(model)
            }
        }
        let presentUIDs = Set(updated.map(\.uid))
        let changedSet = presentUIDs != knownUIDs
        let arrived = presentUIDs.subtracting(knownUIDs)
        knownUIDs = presentUIDs
        devices = updated
        refreshBridges()
        sortDevices()
        if changedSet {
            tapEngine?.audioDevicesChanged()
            restoreVolumes(forArrived: arrived)
            applyOutputPriority()
            updateVirtualTarget(reattaching: arrived)
        }
    }

    /// 重算所有無軟體音量裝置的 DDC 橋接。
    /// 首次橋接常敗在時序：音訊 snapshot 比 DDC 能力探測先到，當時還沒有
    /// 任何 .ddc 顯示器可配。DisplayManager 每次 refresh 完成後回呼這裡補配；
    /// DDC 降級（gammaOnly）時也在此清掉失效的橋接。
    func refreshBridges() {
        for device in devices where !device.canSetVolume {
            // 使用者標記不支援 DDC 音量 → 不橋接，滑桿誠實停用
            let target = settings.audioBridgeDisabled.contains(device.uid)
                ? nil
                : bridgeTarget(forDeviceNamed: device.name)
            if device.bridgedDisplayID != target?.id {
                let isNewBridge = device.bridgedDisplayID == nil
                device.bridgedDisplayID = target?.id
                if isNewBridge, let target {
                    initializeBridgedVolume(device: device, display: target)
                }
            }
        }
        updateVirtualTarget()
        updateVirtualMirrorMode()
        refreshSoftwareVolume()
    }

    /// 決定裝置級處理（軟體音量＋EQ）目前生效在哪個裝置上（最多一個）。
    ///
    /// 兩者共用同一條全域 tap——它們處理的是同一路音訊，各開一條就是
    /// 處理兩次（DESIGN §2.2）。因此對象一定是**目前的預設輸出**：
    /// 全域 tap 抓的是系統混音，不是某個裝置的匯流排。
    ///
    /// 軟體音量還要多過三後端矩陣的順位：使用者為它開了開關、前兩條
    /// 都走不通。少任何一項就只留 EQ，滑桿回到「誠實停用」並附上原因。
    private func refreshSoftwareVolume() {
        let engineReady = tapEngine?.state == .active
        let defaultDevice = devices.first(where: \.isDefault)
        let volumeTarget = defaultDevice.flatMap { device in
            engineReady && isSoftwareVolumeEnabled(device) && canUseSoftwareVolume(device)
                ? device : nil
        }
        for device in devices {
            device.softwareVolumeActive = device.uid == volumeTarget?.uid
        }
        if let target = volumeTarget {
            // 上次記住的值（滑桿在裝置沒有可讀音量時的唯一來源）
            target.volume = settings.lastVolume(for: target.uid) ?? target.volume
        }
        guard engineReady, let defaultDevice else {
            tapEngine?.updateDeviceProcessing(deviceUID: nil, gain: 1, muted: false, eq: nil)
            return
        }
        let eq = effectiveEQ(for: defaultDevice.uid)
        guard volumeTarget != nil || eq != nil else {
            // 兩個都不需要 → 一個 tap 都不建（DESIGN §2.3 規則 2）
            tapEngine?.updateDeviceProcessing(deviceUID: nil, gain: 1, muted: false, eq: nil)
            return
        }
        pushDeviceProcessing(defaultDevice)
    }

    /// 音量只有在軟體音量後端生效時才由我們衰減——否則裝置音量歸
    /// 前兩條後端管，這裡送 1.0（責任矩陣 §3.2：一層只管一件事）。
    private func pushDeviceProcessing(_ device: AudioDeviceModel) {
        let usesSoftwareVolume = device.softwareVolumeActive
        tapEngine?.updateDeviceProcessing(
            deviceUID: device.uid,
            gain: usesSoftwareVolume ? Float(device.volume) : 1,
            muted: usesSoftwareVolume ? device.muted : false,
            eq: effectiveEQ(for: device.uid)
        )
    }

    // MARK: - 裝置優先順序（B6-7）

    func priorityIndex(of device: AudioDeviceModel) -> Int? {
        settings.outputPriority.firstIndex(of: device.uid)
    }

    func addToPriority(_ device: AudioDeviceModel) {
        guard !settings.outputPriority.contains(device.uid) else { return }
        settings.outputPriority.append(device.uid)
    }

    func removeFromPriority(_ device: AudioDeviceModel) {
        settings.outputPriority.removeAll { $0 == device.uid }
    }

    func movePriority(_ device: AudioDeviceModel, up: Bool) {
        guard let index = priorityIndex(of: device) else { return }
        let target = up ? index - 1 : index + 1
        guard settings.outputPriority.indices.contains(target) else { return }
        settings.outputPriority.swapAt(index, target)
    }

    /// 順位最前、且現在接著的裝置成為預設輸出。
    ///
    /// 只在**裝置清單變動時**呼叫（插拔耳機、AirPlay 上下線）。
    /// 每次 snapshot 都跑的話，使用者手動切到別的裝置會在一秒內被搶回來
    /// ——那是 bug 不是功能。規則本身在 `OutputPriority`（純函式、有測試）。
    private func applyOutputPriority() {
        let target = OutputPriority.preferred(
            order: settings.outputPriority,
            present: Set(devices.map(\.uid)),
            current: defaultDevice?.uid
        )
        guard let target, let device = devices.first(where: { $0.uid == target }) else { return }
        setAsDefault(device)
    }

    /// 剛接上的裝置還原上次的音量。
    private func restoreVolumes(forArrived arrived: Set<String>) {
        for uid in OutputPriority.devicesToRestore(order: settings.outputPriority, arrived: arrived) {
            guard let device = devices.first(where: { $0.uid == uid }),
                  device.canSetVolume,
                  let remembered = settings.lastVolume(for: uid)
            else { continue }
            writeVolume(remembered, to: device)
        }
    }

    // MARK: - 每裝置等化（B6-5）

    func eqSettings(for device: AudioDeviceModel) -> EQSettings {
        settings.deviceEQ[device.uid] ?? EQSettings()
    }

    func setEQSettings(_ eq: EQSettings, for device: AudioDeviceModel) {
        if eq == EQSettings() {
            settings.deviceEQ.removeValue(forKey: device.uid)
        } else {
            settings.deviceEQ[device.uid] = eq
        }
        refreshSoftwareVolume()
    }

    /// A/B 旁通：暫時送出一份不同的 EQ（通常是關掉的）而**不動存起來的
    /// 設定**。存進設定會讓「比較完忘了打開」變成使用者的問題，
    /// 而那個 preset 可能是他花十分鐘調的。
    func setEQOverride(_ eq: EQSettings?, for device: AudioDeviceModel) {
        if let eq { eqOverrides[device.uid] = eq } else { eqOverrides.removeValue(forKey: device.uid) }
        refreshSoftwareVolume()
    }

    private func effectiveEQ(for uid: String) -> EQSettings? {
        let eq = eqOverrides[uid] ?? settings.deviceEQ[uid]
        return eq.flatMap { $0.isActive ? $0 : nil }
    }

    /// EQ 為什麼沒生效。開了開關卻沒聲音變化是最難自己查的失敗模式，
    /// 每一種都要講出來。
    func eqUnavailableReason(for device: AudioDeviceModel) -> String? {
        guard eqSettings(for: device).isEnabled else { return nil }
        if !device.isDefault { return "等化只在此裝置是預設輸出時生效" }
        switch tapEngine?.state {
        case .active: return nil
        case .denied: return "系統音訊錄製權限被拒——等化無法運作"
        case .off, nil: return "需要先在設定 → 音訊開啟「App 音訊接管」"
        default: return "正在確認權限…"
        }
    }

    // MARK: - BV 虛擬裝置音量鏡射

    /// 虛擬裝置的音量變更（Touch Bar／音量鍵／滑桿）→ 轉送目標若是
    /// DDC 橋接的螢幕裝置，走既有 writeVolume 路徑鏡射到 VCP 0x62
    /// （螢幕裝置的滑桿與寫後驗證都跟著動）。無 DDC 時不鏡射——
    /// driver 端 applyVolume=1 的數位衰減就是音量本體。
    private func mirrorVirtualVolume(_ value: Double) {
        guard let target = mirrorTarget() else { return }
        writeVolume(value, to: target)
    }

    private func mirrorVirtualMute(_ muted: Bool) {
        guard let target = mirrorTarget() else { return }
        writeMute(muted, to: target)
    }

    /// 鏡射目標：driver 設定的轉送裝置，且必須是 DDC 橋接的螢幕裝置。
    private func mirrorTarget() -> AudioDeviceModel? {
        guard let uid = virtualDriver?.targetUID,
              let target = devices.first(where: { $0.uid == uid }),
              !target.canSetVolume,
              target.bridgedDisplayID != nil
        else { return nil }
        return target
    }

    // MARK: - 轉送目標：跟著使用中的螢幕走

    /// 重算虛擬裝置該把聲音送到哪裡，需要時寫回 driver。
    ///
    /// 順位：使用者指定的裝置（還在的話）→ 使用中那台螢幕的音訊裝置 →
    /// 其他還亮著的螢幕 → 任何螢幕音訊裝置 → **內建輸出**。最後一條是
    /// 重點：螢幕被關掉／拔掉時寧可從 Mac 喇叭出來，也不要靜靜沒有聲音。
    ///
    /// 只在裝置清單或顯示器配置變動時重算——不跟著視窗焦點跑，
    /// 否則點一下另一台螢幕上的視窗就會把播到一半的音訊切走。
    ///
    /// `reattaching` 是這一輪新出現的裝置：目標**重新出現**時即使 UID 沒變
    /// 也要重寫一次設定。螢幕關掉再開之後聲音不會自己回來（driver 在裝置
    /// 還沒就緒時就接上了，之後不會再收到通知），非得手動切一次輸出才恢復。
    func updateVirtualTarget(reattaching arrived: Set<String> = []) {
        guard let virtualDriver,
              devices.contains(where: { $0.uid == VirtualAudioDriverController.deviceUID }),
              let target = preferredVirtualTargetUID()
        else { return }
        if virtualDriver.targetUID == target {
            guard arrived.contains(target) else { return }
            // 同一個 UID 回來了：延遲一下再重寫，讓裝置先就緒
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                guard let self, self.virtualDriver?.targetUID == target,
                      self.devices.contains(where: { $0.uid == target }) else { return }
                self.virtualDriver?.setTarget(uid: target)
                self.updateVirtualMirrorMode()
            }
            return
        }
        virtualDriver.setTarget(uid: target)
        updateVirtualMirrorMode()
    }

    /// 轉送目標的順位計算。規則本身在 `VirtualOutputTarget`（純函式、有測試），
    /// 這裡只負責把「使用中的螢幕」「還亮著的螢幕」翻成音訊裝置 UID。
    private func preferredVirtualTargetUID() -> String? {
        let liveDisplays = (displayManager?.displays ?? []).filter { !$0.isPoweredOff }
        let activeDisplay = Self.activeDisplayID.flatMap { id in
            liveDisplays.first { $0.id == id }
        }
        return VirtualOutputTarget.preferred(
            pinned: settings.virtualTargetUID,
            present: Set(devices.map(\.uid)),
            activeScreen: activeDisplay.flatMap { screenAudioDevice(for: $0)?.uid },
            liveScreens: liveDisplays.compactMap { screenAudioDevice(for: $0)?.uid },
            anyScreens: devices.filter(isScreenAudioDevice).map(\.uid),
            builtin: devices.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn }?.uid
        )
    }

    /// 螢幕自己的音訊端點（HDMI／DisplayPort）。虛擬裝置不算。
    private func isScreenAudioDevice(_ device: AudioDeviceModel) -> Bool {
        guard device.uid != VirtualAudioDriverController.deviceUID else { return false }
        return device.transportType == kAudioDeviceTransportTypeHDMI
            || device.transportType == kAudioDeviceTransportTypeDisplayPort
    }

    /// 這台螢幕對應的音訊裝置（名稱吻合；與 `bridgeTarget` 是同一套比對）。
    private func screenAudioDevice(for display: DisplayModel) -> AudioDeviceModel? {
        devices.first { device in
            isScreenAudioDevice(device)
                && (device.name.localizedCaseInsensitiveContains(display.name)
                    || display.name.localizedCaseInsensitiveContains(device.name))
        }
    }

    /// 使用中的螢幕：有鍵盤焦點的那一台（沒有視窗時是滑鼠所在的那台）。
    private static var activeDisplayID: CGDirectDisplayID? {
        guard let screen = NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }

    /// 依鏡射可用性切 driver 模式：DDC 通 → 鏡射（樣本原樣通過）；
    /// 不通 → driver 內數位衰減。只在值改變時打設定通道。
    func updateVirtualMirrorMode() {
        guard let virtualDriver,
              devices.contains(where: { $0.uid == VirtualAudioDriverController.deviceUID })
        else { return }
        let mirrors = mirrorTarget().map { !$0.bridgeUnresponsive } ?? false
        virtualDriver.setMirrorMode(mirrors)
    }

    /// 橋接建立時讀螢幕的 VCP 0x62 現值回填滑桿（否則只能猜上次記住的值，
    /// 滑桿位置對不上硬體）。該螢幕停用 DDC 讀取時跳過。
    private func initializeBridgedVolume(device: AudioDeviceModel, display: DisplayModel) {
        guard !settings.disableDDCRead.contains(display.uuid) else { return }
        let displayID = display.id
        let uid = device.uid
        Task { [weak self] in
            guard let ddc = self?.displayManager?.ddc else { return }
            if let result = await ddc.read(displayID, vcp: DDCController.VCP.volume), result.max > 0 {
                guard let self, let model = self.devices.first(where: { $0.uid == uid }),
                      model.bridgedDisplayID == displayID else { return }
                model.bridgeVolumeMax = result.max
                let value = Double(result.current) / Double(result.max)
                model.volume = value
                self.settings.setLastVolume(value, for: uid)
            }
            // 靜音狀態也回讀（0x8D：1=靜音 2=未靜音），避免模型與螢幕脫鉤
            if let muteResult = await ddc.read(displayID, vcp: DDCController.VCP.mute) {
                guard let self, let model = self.devices.first(where: { $0.uid == uid }),
                      model.bridgedDisplayID == displayID else { return }
                model.muted = muteResult.current == DDCController.MuteValue.muted
            }
        }
    }

    /// 內建優先、其次依名稱排序。
    private func sortDevices() {
        var updated = devices
        updated.sort { lhs, rhs in
            let lhsBuiltin = lhs.transportType == kAudioDeviceTransportTypeBuiltIn
            let rhsBuiltin = rhs.transportType == kAudioDeviceTransportTypeBuiltIn
            if lhsBuiltin != rhsBuiltin { return lhsBuiltin }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        devices = updated
    }

    /// 300ms 內我們自己寫過相近值 → 保留 UI 值，避免硬體量化造成 slider 抖動。
    private func shouldPreserveLocalValue(uid: String, reported: Double) -> Bool {
        guard let recent = recentLocalSets[uid] else { return false }
        guard ContinuousClock.now - recent.at < .milliseconds(300) else {
            recentLocalSets.removeValue(forKey: uid)
            return false
        }
        return abs(recent.value - reported) < 0.05
    }

    /// 無軟體音量的裝置 → 對應的 DDC 顯示器。
    /// 名稱吻合優先；否則若只有一台 DDC 外接螢幕就用它。
    private func bridgeTarget(forDeviceNamed name: String) -> DisplayModel? {
        guard let displays = displayManager?.displays else { return nil }
        let ddcDisplays = displays.filter { $0.backend == .ddc }
        if let match = ddcDisplays.first(where: {
            $0.name.localizedCaseInsensitiveContains(name) || name.localizedCaseInsensitiveContains($0.name)
        }) {
            return match
        }
        return ddcDisplays.count == 1 ? ddcDisplays.first : nil
    }
}
