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
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var pollerTask: Task<Void, Never>?
    @ObservationIgnored weak var coordinator: ControlCoordinator?
    @ObservationIgnored weak var autoController: AutoBrightnessController?
    /// DDC 能力分類完成後回呼音訊層重算橋接（音訊 snapshot 常比 DDC 探測先到）。
    @ObservationIgnored weak var audioManager: AudioDeviceManager?

    init(settings: SettingsStore) {
        self.settings = settings
    }

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
        AppStateRegistry.displayManager = self
    }

    func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { await refresh() }
    }

    /// 重新列舉顯示器並分類能力。
    func refresh() async {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return }
        // 排除硬體鏡像的從屬顯示器
        let activeIDs = ids.prefix(Int(count)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }

        // 先分出 DisplayServices 可控的（內建與 Apple 顯示器），其餘嘗試 DDC
        var classified: [(id: CGDirectDisplayID, backend: BrightnessBackend)] = []
        var ddcCandidates: [CGDirectDisplayID] = []
        for id in activeIDs {
            if displayServices.canChangeBrightness(id) {
                classified.append((id, .displayServices))
            } else {
                ddcCandidates.append(id)
            }
        }
        let ddcCapable = await ddc.refresh(displayIDs: ddcCandidates)
        guard !Task.isCancelled else { return }
        for id in ddcCandidates {
            classified.append((id, ddcCapable.contains(id) ? .ddc : .gammaOnly))
        }

        var models: [DisplayModel] = []
        for (id, backend) in classified {
            let uuid = Self.stableUUID(for: id)
            let force = settings.forceSoftwareDimming.contains(uuid)
            let brightness = await initialBrightness(id: id, uuid: uuid, backend: backend)
            guard !Task.isCancelled else { return }
            models.append(DisplayModel(
                id: id,
                uuid: uuid,
                name: Self.name(for: id),
                isBuiltin: CGDisplayIsBuiltin(id) != 0,
                backend: backend,
                forceSoftwareDimming: force,
                brightness: brightness
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
                ddc.write(model.id, vcp: DDCController.VCP.brightness, value: UInt16((hardware * 100).rounded()))
            case .displayServices:
                displayServices.setBrightness(hardware, for: model.id)
            case .gammaOnly:
                break
            }
        }
        gamma.setFactor(output.softwareFactor, for: model.id)
    }

    /// 讀取初始亮度：DisplayServices 直接讀；DDC 讀一次（除非該螢幕停用 read）；
    /// 讀不到時用上次記住的值，再不行取 0.5。
    private func initialBrightness(id: CGDirectDisplayID, uuid: String, backend: BrightnessBackend) async -> Double {
        switch backend {
        case .displayServices:
            if let value = displayServices.brightness(for: id) { return value }
        case .ddc:
            if !settings.disableDDCRead.contains(uuid),
               let (current, max) = await ddc.read(id, vcp: DDCController.VCP.brightness),
               max > 0 {
                return Double(current) / Double(max)
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
}
