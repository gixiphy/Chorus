import AppKit
import ChorusCore
import CoreGraphics
import Foundation
import Observation

/// 顯示器列舉、能力分類與亮度控制的入口。
/// 本身只在 MainActor 上做清單管理；實際 IO 交給 DDCController（serial queue）、
/// DisplayServicesClient（快速 IPC）與 GammaDimmer。
@MainActor
@Observable
final class DisplayManager {
    private(set) var displays: [DisplayModel] = []

    @ObservationIgnored let ddc = DDCController()
    @ObservationIgnored private let displayServices = DisplayServicesClient()
    @ObservationIgnored private let gamma = GammaDimmer()
    @ObservationIgnored private let softDisconnect = SoftDisconnectClient()
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var screenObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pollerTask: Task<Void, Never>?
    @ObservationIgnored weak var coordinator: ControlCoordinator?
    @ObservationIgnored weak var autoController: AutoBrightnessController?
    /// DDC 能力分類完成後回呼音訊層重算橋接（音訊 snapshot 常比 DDC 探測先到）。
    @ObservationIgnored weak var audioManager: AudioDeviceManager?
    /// 螢幕組合變更後通知桌面情境自動切換（防抖在對方）。
    @ObservationIgnored weak var scenarioStore: DeskScenarioStore?
    /// 「接著某台螢幕時防睡眠」需要知道螢幕組合何時變動。
    @ObservationIgnored weak var keepAwake: KeepAwakeController?
    /// 有螢幕被關掉時才掛上 ⌘×8 手勢監聽（見 EmergencyRestoreMonitor）。
    @ObservationIgnored weak var emergencyRestore: EmergencyRestoreMonitor?
    /// 顯示器組合變更要進自動化事件流（CLI listen 的訂閱者靠它重抓清單）。
    @ObservationIgnored weak var automationEvents: AutomationEventHub?

    /// 被我們關掉、並因此從 active list 消失的顯示器（uuid → model）。
    ///
    /// soft-disconnect **一定**會讓顯示器離開 `CGGetActiveDisplayList`，
    /// DDC DPMS off 則視螢幕而定。若不留一份，下一次 refresh 就會把它從
    /// `displays` 刪掉——電源鈕跟著消失，使用者再也開不回來（只能結束 App
    /// 靠 kCGConfigureForAppOnly 還原）。refresh 時一律補回清單。
    @ObservationIgnored private var poweredOffModels: [String: DisplayModel] = [:]

    init(settings: SettingsStore) {
        self.settings = settings
    }

    /// 睡醒後螢幕 scaler／I2C 尚未就緒，貿然讀寫會失敗甚至誤判能力。
    /// 此期間 DDC 寫入延後、能力重探測也等這麼久才跑。
    private static let wakeSettleDelay: TimeInterval = 3.0

    func start() {
        ddc.setPersistentFailureHandler { displayID in
            Task { @MainActor in
                AppStateRegistry.displayManager?.handleDDCFailure(displayID)
            }
        }
        scheduleRefresh()
        startBrightnessPoller()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppStateRegistry.displayManager?.scheduleRefresh()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppStateRegistry.displayManager?.handleScreensWake()
            }
        }
        AppStateRegistry.displayManager = self
    }

    /// 螢幕喚醒：DDC 寫入延後、重新分類也等靜置期過後才做
    /// （太早探測會把還沒醒的螢幕誤判成不支援 DDC）。
    private func handleScreensWake() {
        ddc.deferWrites(for: Self.wakeSettleDelay)
        scheduleRefresh(after: Self.wakeSettleDelay)
    }

    func scheduleRefresh(after delay: TimeInterval = 0) {
        refreshTask?.cancel()
        refreshTask = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            await refresh()
        }
    }

    /// 重新列舉顯示器並分類能力。
    func refresh() async {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return }
        // 排除硬體鏡像的從屬顯示器
        let activeIDs = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }

        // 先分出 DisplayServices 可控的（內建與 Apple 顯示器），其餘嘗試 DDC
        typealias VCPProbe = (current: UInt16, max: UInt16)
        var classified: [(id: CGDirectDisplayID, backend: BrightnessBackend, probe: VCPProbe?, contrastProbe: VCPProbe?)] = []
        var ddcCandidates: [CGDirectDisplayID] = []
        var ddcPowerCapable: Set<CGDirectDisplayID> = []
        for id in activeIDs {
            if displayServices.canChangeBrightness(id) {
                classified.append((id, .displayServices, nil, nil))
            } else {
                ddcCandidates.append(id)
            }
        }
        let ddcCapable = await ddc.refresh(displayIDs: ddcCandidates)
        guard !Task.isCancelled else { return }
        for id in ddcCandidates {
            guard ddcCapable.contains(id) else {
                classified.append((id, .gammaOnly, nil, nil))
                continue
            }
            // Service 配對只代表 I2C 端點存在；Mac mini 內建 HDMI 這類路徑
            // 會 ACK 寫入但不透傳（實測 Q34E2G5：寫「成功」、讀全失敗、螢幕沒反應）。
            // 以讀取驗證：讀得回亮度才承認 DDC；使用者停用讀取時信任寫入。
            // 讀值同時是初始亮度與值域上限的來源（不重複打 I2C）。
            let uuid = Self.stableUUID(for: id)
            if settings.disableDDCRead.contains(uuid) {
                classified.append((id, .ddc, nil, nil))
            } else if let probe = await ddc.read(id, vcp: DDCController.VCP.brightness), probe.max > 0 {
                // 對比順手探（讀得到才有對比 UI；讀不到＝不支援 0x12，靜默略過）
                let contrastProbe = await ddc.read(id, vcp: DDCController.VCP.contrast)
                classified.append((id, .ddc, probe, contrastProbe))
                // 電源 VCP 0xD6：讀得回來才承認支援（同亮度的讀取驗證紀律）
                if await ddc.read(id, vcp: DDCController.VCP.power) != nil {
                    ddcPowerCapable.insert(id)
                }
            } else {
                classified.append((id, .gammaOnly, nil, nil))
            }
            guard !Task.isCancelled else { return }
        }

        var models: [DisplayModel] = []
        for (id, backend, probe, contrastProbe) in classified {
            let uuid = Self.stableUUID(for: id)
            let force = settings.forceSoftwareDimming.contains(uuid)
            var brightness = initialBrightness(id: id, uuid: uuid, backend: backend, probe: probe)
            // Sub-zero 顯示器：讀回的是硬體值，要反映射回滑桿值；
            // 硬體 0（gamma 區間）無法還原 → 用上次記住的滑桿值
            if backend == .ddc, probe != nil, settings.subZeroDimming.contains(uuid) {
                let pipeline = BrightnessPipeline(softwareThreshold: Self.subZeroThreshold)
                brightness = pipeline.sliderValue(forHardware: brightness)
                    ?? settings.lastBrightness(for: uuid) ?? 0.5
            }
            let contrast: Double? = contrastProbe.flatMap { $0.max > 0 ? Double($0.current) / Double($0.max) : nil }
            models.append(DisplayModel(
                id: id,
                uuid: uuid,
                name: Self.name(for: id),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                backend: backend,
                forceSoftwareDimming: force,
                subZeroDimming: settings.subZeroDimming.contains(uuid),
                brightness: brightness,
                ddcBrightnessMax: probe?.max ?? 100,
                contrast: contrast,
                ddcContrastMax: contrastProbe?.max ?? 100,
                supportsDDCPower: ddcPowerCapable.contains(id),
                powerLayer: .gammaBlackout // 下面依總數重算
            ))
        }

        // 關機狀態要跨 refresh 保留，但「還在不在 active list」的意義分層不同：
        //   soft-disconnect：關掉就會離開 active list ⇒ 又出現＝已被接回來，
        //                    旗標必須清掉（否則 UI 顯示已關、實際亮著）。
        //   DDC／gamma：螢幕本來就留在 active list ⇒ 重建 model 時要把旗標帶回來，
        //               否則任何一次 refresh 都會把「已關閉」洗成「開著」。
        let presentUUIDs = Set(models.map(\.uuid))
        for model in models {
            guard let offModel = poweredOffModels[model.uuid] else { continue }
            if offModel.powerLayer == .softDisconnect {
                poweredOffModels.removeValue(forKey: model.uuid)
            } else {
                model.isPoweredOff = true
                // 沿用「當初實際關掉時用的層」，不是重新推薦的層
                model.powerLayer = offModel.powerLayer
                poweredOffModels[model.uuid] = model
            }
        }
        // 被我們關掉而從 active list 消失的顯示器補回清單（見 poweredOffModels）
        for (uuid, offModel) in poweredOffModels where !presentUUIDs.contains(uuid) {
            models.append(offModel)
        }
        // 選層要知道「是不是只剩這一台」，因此等清單齊了才算。
        // **關閉中的不重算**：powerLayer 記的是「我們當初用哪一層關的」，
        // 要靠它走對還原路徑。重算會讓 gamma 全黑的螢幕被標成 soft-disconnect，
        // 開回來時呼叫 setEnabled(true) 對一台從未被 disable 的顯示器──
        // 什麼都沒發生，螢幕就永遠黑著了。
        let isOnly = models.count <= 1
        for model in models where !model.isPoweredOff {
            model.powerLayer = DisplayPowerPlanner.layer(for: DisplayPowerCapability(
                supportsDDCPower: model.supportsDDCPower,
                supportsSoftDisconnect: softDisconnect.isAvailable,
                isOnlyActiveDisplay: isOnly
            ))
        }
        // 內建排最前，其餘依名稱
        models.sort { lhs, rhs in
            if lhs.isBuiltin != rhs.isBuiltin { return lhs.isBuiltin }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        // 已消失的顯示器丟棄 gamma 快取（關機中的除外——它們只是被我們
        // 移出 layout，快取還要用來還原）
        let newIDs = Set(models.map(\.id))
        for old in displays where !newIDs.contains(old.id) && poweredOffModels[old.uuid] == nil {
            gamma.forget(old.id)
        }
        displays = models
        reapplySoftwareDimming()
        audioManager?.refreshBridges()
        // 情境切換與防睡眠看的是「實體接著哪些螢幕」——被 Chorus 關掉的
        // 螢幕線還在，算連接中，否則關個螢幕就會誤觸桌面情境自動切換。
        scenarioStore?.displaysDidChange(Set(models.map(\.uuid)))
        keepAwake?.displaysDidChange()
        automationEvents?.publish(kind: "displays", payload: ["names": models.map(\.name)])
    }

    /// 使用者透過 UI 設定亮度（會廣播同步）。value 0–1。
    /// 自動亮度管理中的顯示器：改為差異值學習，不廣播（auto 受管顯示器不發 .brightness）。
    func setBrightness(_ value: Double, for model: DisplayModel) {
        let clamped = min(max(value, 0), 1)
        model.brightness = clamped
        settings.setLastBrightness(clamped, for: model.uuid)
        apply(model)
        if let autoController, autoController.isAutoActive(for: model.uuid) {
            autoController.learnOffsetFromManualSet(uuid: model.uuid, value: clamped)
            return
        }
        coordinator?.localBrightnessChanged(clamped)
    }

    /// 遠端同步套用：所有顯示器設為同一亮度。**不**觸發廣播。
    /// 自動亮度管理中的顯示器不套用（auto 受管顯示器不收 .brightness）。
    func applySyncedBrightness(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        for model in displays {
            if let autoController, autoController.isAutoActive(for: model.uuid) { continue }
            model.brightness = clamped
            settings.setLastBrightness(clamped, for: model.uuid)
            apply(model)
        }
    }

    /// 遙控命令：語意同本機手動調整——auto 受管的顯示器套用後學進差異值
    /// （否則會被 applySyncedBrightness 的 auto 抑制吞掉、下一輪 auto 又拉回），
    /// 非受管顯示器直接套用並廣播。
    func applyCommandBrightness(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        var appliedNonAuto = false
        for model in displays {
            model.brightness = clamped
            settings.setLastBrightness(clamped, for: model.uuid)
            apply(model)
            if let autoController, autoController.isAutoActive(for: model.uuid) {
                autoController.learnOffsetFromManualSet(uuid: model.uuid, value: clamped)
            } else {
                appliedNonAuto = true
            }
        }
        if appliedNonAuto {
            coordinator?.localBrightnessChanged(clamped)
        }
    }

    /// 遙控指定顯示器（UUID 不存在時 no-op）。**不**觸發廣播。
    func applyBrightness(_ value: Double, toUUID uuid: String) {
        guard let model = displays.first(where: { $0.uuid == uuid }) else { return }
        let clamped = min(max(value, 0), 1)
        model.brightness = clamped
        settings.setLastBrightness(clamped, for: model.uuid)
        apply(model)
    }

    func setForceSoftwareDimming(_ enabled: Bool, for model: DisplayModel) {
        model.forceSoftwareDimming = enabled
        var set = settings.forceSoftwareDimming
        if enabled { set.insert(model.uuid) } else { set.remove(model.uuid) }
        settings.forceSoftwareDimming = set
        if !enabled {
            gamma.restore(model.id)
        }
        apply(model)
    }

    func setSubZeroDimming(_ enabled: Bool, for model: DisplayModel) {
        model.subZeroDimming = enabled
        var set = settings.subZeroDimming
        if enabled { set.insert(model.uuid) } else { set.remove(model.uuid) }
        settings.subZeroDimming = set
        if !enabled {
            gamma.restore(model.id)
        }
        apply(model)
    }

    /// Sub-zero dimming 啟用時滑桿下段（此值以下）改走 gamma。
    /// 同步協定不受影響：跨機傳的是 0–1 滑桿值，各機依自己的 pipeline 映射。
    private static let subZeroThreshold = 0.25

    /// Sub-zero 只給 DDC 螢幕：DisplayServices 顯示器的 poller 以硬體值
    /// 對帳 model，滑桿≠硬體的映射會被誤判成外部變更而互相拉扯
    private func pipeline(for model: DisplayModel) -> BrightnessPipeline {
        BrightnessPipeline(
            softwareThreshold: model.subZeroDimming && model.backend == .ddc && model.hasHardwareControl
                ? Self.subZeroThreshold : 0
        )
    }

    private func apply(_ model: DisplayModel) {
        let output = pipeline(for: model).map(
            slider: model.brightness,
            hasHardwareControl: model.hasHardwareControl
        )

        if let hardware = output.hardware {
            switch model.backend {
            case .ddc:
                // 依螢幕自報的 0x10 值域縮放（多數 100，也有 255 的）
                ddc.write(
                    model.id,
                    vcp: DDCController.VCP.brightness,
                    value: UInt16((hardware * Double(model.ddcBrightnessMax)).rounded())
                )
            case .displayServices:
                displayServices.setBrightness(hardware, for: model.id)
            case .gammaOnly:
                break
            }
        }
        gamma.setFactor(output.softwareFactor, for: model.id)
    }

    /// refresh 後重新套用軟體調光。
    ///
    /// 顯示器組態變更（解析度切換、睡醒後 link retraining）會讓 macOS 重設
    /// gamma transfer table：調光靜靜失效、螢幕跳回全亮，滑桿卻還停在調暗的值。
    ///
    /// 只重下 gamma，不碰 DDC／DisplayServices——硬體亮度就是剛剛探測到的現值，
    /// 補寫 I2C 只會在每次螢幕參數變動時多打一輪沒必要的匯流排流量。
    ///
    /// 只處理「已在調光中」的顯示器（gamma 有快取原始 table）。這是必要的過濾：
    /// 沒有歷史值的顯示器 initialBrightness 會給 0.5 佔位，無條件套用會把剛接上、
    /// 使用者從沒調過的螢幕直接調暗一半。
    ///
    /// setFactor 一律以快取的原始 table 重算，重複套用不會疊加變暗。
    private func reapplySoftwareDimming() {
        for model in displays where gamma.isDimming(model.id) {
            let output = pipeline(for: model).map(
                slider: model.brightness,
                hasHardwareControl: model.hasHardwareControl
            )
            gamma.setFactor(output.softwareFactor, for: model.id)
        }
    }

    /// 初始亮度：DisplayServices 直接讀；DDC 用分類時的讀值（停用 read 時為 nil）；
    /// 讀不到時用上次記住的值，再不行取 0.5。
    private func initialBrightness(
        id: CGDirectDisplayID,
        uuid: String,
        backend: BrightnessBackend,
        probe: (current: UInt16, max: UInt16)?
    ) -> Double {
        switch backend {
        case .displayServices:
            if let value = displayServices.brightness(for: id) { return value }
        case .ddc:
            if let probe, probe.max > 0 {
                return Double(probe.current) / Double(probe.max)
            }
        case .gammaOnly:
            break
        }
        return settings.lastBrightness(for: uuid) ?? 0.5
    }

    /// 偵測鍵盤亮度鍵等外部變更：輪詢 DisplayServices 顯示器的實際亮度，
    /// 與 model 有落差時視為本地硬體變更 → 更新 UI 並廣播同步。
    /// （遠端套用會先更新 model，因此不會被誤判成本地變更。）
    private func startBrightnessPoller() {
        pollerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.pollBuiltinBrightness()
            }
        }
    }

    private func pollBuiltinBrightness() {
        for model in displays where model.backend == .displayServices {
            guard let actual = displayServices.brightness(for: model.id) else { continue }
            if abs(actual - model.brightness) > 0.005 {
                // 自動亮度管理中：交給 controller 對帳（自身寫入收斂 vs 使用者按鍵
                // → 差異值學習），兩種情況都只更新 model、不廣播。
                if let autoController,
                   autoController.handleExternalBrightnessChange(uuid: model.uuid, actual: actual) {
                    model.brightness = actual
                    settings.setLastBrightness(actual, for: model.uuid)
                    continue
                }
                model.brightness = actual
                settings.setLastBrightness(actual, for: model.uuid)
                coordinator?.localBrightnessChanged(actual)
            }
        }
    }

    /// 切換輸入源（VCP 0x60）。切走後這台 Mac 通常會失去該螢幕——
    /// 這是使用者要的效果（KVM 情境），不是錯誤。
    /// one-shot：輸入源可能被螢幕按鈕或另一台機器改走，去重快取不可信。
    func setInput(_ code: UInt16, for model: DisplayModel) {
        guard model.backend == .ddc else { return }
        ddc.write(model.id, vcp: DDCController.VCP.inputSource, value: code, oneShot: true)
    }

    /// 遙控切換指定顯示器的輸入源（UUID 不存在時 no-op）。
    /// 這正是 KVM 的關鍵動作：螢幕被切到別台後，本機 UI 摸不到它，
    /// 只有對方機器能把它切回來。
    func applyInput(_ code: UInt16, toUUID uuid: String) {
        guard let model = displays.first(where: { $0.uuid == uuid }) else { return }
        setInput(code, for: model)
    }

    /// 對比 VCP 0x12（0–1，依螢幕自報值域縮放）。只在探測到對比的螢幕上有 UI。
    func setContrast(_ value: Double, for model: DisplayModel) {
        guard model.backend == .ddc else { return }
        let clamped = min(max(value, 0), 1)
        model.contrast = clamped
        ddc.write(
            model.id,
            vcp: DDCController.VCP.contrast,
            value: UInt16((clamped * Double(model.ddcContrastMax)).rounded())
        )
    }

    /// 遙控設定指定顯示器的對比（UUID 不存在時 no-op）。
    func applyContrast(_ value: Double, toUUID uuid: String) {
        guard let model = displays.first(where: { $0.uuid == uuid }) else { return }
        setContrast(value, for: model)
    }

    // MARK: - 螢幕電源（M9 三層）

    /// 使用者按電源鈕。層別由 refresh 時算好的 `powerLayer` 決定，
    /// UI 不需要知道底下走的是哪一條路。
    func setDisplayPower(_ on: Bool, for model: DisplayModel) {
        // 已經是目標狀態就不重複動作。要「開」時必須現在是關的、
        // 要「關」時必須現在是開的——兩者都等價於 isPoweredOff == on。
        guard model.isPoweredOff == on else { return }
        if on { powerOn(model) } else { powerOff(model) }
    }

    /// 遙控指定顯示器（UUID 不存在時 no-op）。**不**觸發廣播。
    func applyDisplayPower(_ on: Bool, toUUID uuid: String) {
        guard let model = displays.first(where: { $0.uuid == uuid }) else { return }
        setDisplayPower(on, for: model)
    }

    /// 遙控本機所有顯示器（語意層 `.displayPower(nil)`）。
    /// 開啟走 restoreAll——連從 active list 掉出去的都撈回來。
    func applyCommandDisplayPower(_ on: Bool) {
        if on {
            restoreAllDisplayPower()
        } else {
            for model in displays { setDisplayPower(false, for: model) }
        }
    }

    /// 全部復原。⌘×8 緊急手勢、選單項目與 App 結束都走這裡。
    /// 回傳實際復原了幾台（手勢要據此決定是否給回饋）。
    @discardableResult
    func restoreAllDisplayPower() -> Int {
        var restored = 0
        var handled: Set<String> = []
        for model in displays where model.isPoweredOff {
            powerOn(model)
            handled.insert(model.uuid)
            restored += 1
        }
        // 保險：refresh 還沒把 registry 併回清單的空窗期
        for (uuid, model) in poweredOffModels where !handled.contains(uuid) {
            powerOn(model)
            restored += 1
        }
        return restored
    }

    /// 目前有沒有被我們關掉的螢幕（決定要不要掛緊急手勢監聽）。
    var hasPoweredOffDisplay: Bool {
        !poweredOffModels.isEmpty
    }

    private func powerOff(_ model: DisplayModel) {
        // 選層是在 refresh 時算的，那時的「還剩幾台」可能已經過期：
        // 逐台關下去時，最後一台的 layer 仍寫著 softDisconnect。真的把它
        // 移出 layout 就會一片畫面都不剩，連復原手勢的回饋都看不到。
        // 這裡以當下實況再擋一次——保底層至少還看得到滑鼠指標的位置感。
        if model.powerLayer == .softDisconnect,
           displays.filter({ !$0.isPoweredOff }).count <= 1 {
            model.powerLayer = .gammaBlackout
        }
        switch model.powerLayer {
        case .ddc:
            // one-shot：螢幕可能被實體電源鍵改過狀態，lastWritten 不可信。
            // 只寫 DPMS off（0x04），永不寫 hard off（0x05）——後者有螢幕
            // 關掉後整條 DDC 就不再回應，只能按實體鍵救回。
            ddc.write(model.id, vcp: DDCController.VCP.power, value: DisplayPowerValue.off, oneShot: true)
        case .softDisconnect:
            if !softDisconnect.setEnabled(false, displayID: model.id) {
                // 私有 API 失敗（macOS 改版、顯示器狀態特殊）：誠實降級到
                // gamma 黑屏，並把實際用的層記回 model，開回來時才走對路徑。
                model.powerLayer = .gammaBlackout
                gamma.setBlackout(true, for: model.id)
            }
        case .gammaBlackout:
            gamma.setBlackout(true, for: model.id)
        }
        model.isPoweredOff = true
        poweredOffModels[model.uuid] = model
        emergencyRestore?.updateArming(active: true)
    }

    private func powerOn(_ model: DisplayModel) {
        switch model.powerLayer {
        case .ddc:
            ddc.write(model.id, vcp: DDCController.VCP.power, value: DisplayPowerValue.on, oneShot: true)
        case .softDisconnect:
            softDisconnect.setEnabled(true, displayID: model.id)
        case .gammaBlackout:
            gamma.setBlackout(false, for: model.id)
        }
        model.isPoweredOff = false
        poweredOffModels.removeValue(forKey: model.uuid)
        emergencyRestore?.updateArming(active: !poweredOffModels.isEmpty)
        // 解除全黑會連原始 table 一起還原，亮度要重套回去
        apply(model)
    }

    /// DDC 持續寫入失敗：降級為 gamma 軟體調光，讓 slider 立即恢復作用。
    func handleDDCFailure(_ displayID: CGDirectDisplayID) {
        guard let model = displays.first(where: { $0.id == displayID }),
              model.backend == .ddc
        else { return }
        model.demoteToGammaOnly()
        apply(model)
    }

    /// 應用程式結束前還原：先把關掉的螢幕開回來，再還原 gamma。
    /// soft-disconnect 另有 kCGConfigureForAppOnly 的核心層保險（崩潰時也會還原），
    /// 這裡是正常結束路徑的明確收尾。
    func shutdown() {
        restoreAllDisplayPower()
        gamma.restoreAll()
    }

    private static func stableUUID(for id: CGDirectDisplayID) -> String {
        if let uuidRef = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() {
            return CFUUIDCreateString(nil, uuidRef) as String
        }
        return "display-\(id)"
    }

    private static func name(for id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
               number.uint32Value == id {
                return screen.localizedName
            }
        }
        return CGDisplayIsBuiltin(id) != 0 ? "內建顯示器" : "顯示器"
    }
}

/// NotificationCenter C-style callback 需要一個穩定的參照點；
/// 這裡登記目前的 DisplayManager 供螢幕變更通知使用。
@MainActor
enum AppStateRegistry {
    static var displayManager: DisplayManager?
    static var scenarioStore: DeskScenarioStore?
    static var keepAwake: KeepAwakeController?
    /// 限時場景（B7）。睡醒通知的 observer 靠它回到 controller——
    /// closure 直接捕獲 self 在 Swift 6 的嚴格併發下不合法（non-Sendable
    /// 的 @MainActor 型別），與 keepAwake 的 App observer 同一個理由。
    static var focus: FocusSessionController?
}
