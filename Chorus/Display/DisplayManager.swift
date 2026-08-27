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
            } else {
                classified.append((id, .gammaOnly, nil, nil))
            }
            guard !Task.isCancelled else { return }
        }

        var models: [DisplayModel] = []
        for (id, backend, probe, contrastProbe) in classified {
            let uuid = Self.stableUUID(for: id)
            let force = settings.forceSoftwareDimming.contains(uuid)
            let brightness = initialBrightness(id: id, uuid: uuid, backend: backend, probe: probe)
            let contrast: Double? = contrastProbe.flatMap { $0.max > 0 ? Double($0.current) / Double($0.max) : nil }
            models.append(DisplayModel(
                id: id,
                uuid: uuid,
                name: Self.name(for: id),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                backend: backend,
                forceSoftwareDimming: force,
                brightness: brightness,
                ddcBrightnessMax: probe?.max ?? 100,
                contrast: contrast,
                ddcContrastMax: contrastProbe?.max ?? 100
            ))
        }
        // 內建排最前，其餘依名稱
        models.sort { lhs, rhs in
            if lhs.isBuiltin != rhs.isBuiltin { return lhs.isBuiltin }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        // 已消失的顯示器丟棄 gamma 快取
        let newIDs = Set(models.map(\.id))
        for old in displays where !newIDs.contains(old.id) {
            gamma.forget(old.id)
        }
        displays = models
        audioManager?.refreshBridges()
        scenarioStore?.displaysDidChange(Set(models.map(\.uuid)))
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

    private func apply(_ model: DisplayModel) {
        let pipeline = BrightnessPipeline()
        let output = pipeline.map(slider: model.brightness, hasHardwareControl: model.hasHardwareControl)

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

    /// DDC 持續寫入失敗：降級為 gamma 軟體調光，讓 slider 立即恢復作用。
    func handleDDCFailure(_ displayID: CGDirectDisplayID) {
        guard let model = displays.first(where: { $0.id == displayID }),
              model.backend == .ddc
        else { return }
        model.demoteToGammaOnly()
        apply(model)
    }

    /// 應用程式結束前還原 gamma。
    func shutdown() {
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
}
