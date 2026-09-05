import ChorusCore
import Foundation
import Observation

/// 自動亮度迴路：光感器（本機或遠端 peer）→ 曲線 + 差異值 → 各顯示器亮度。
///
/// 基準來源位階：本機感器 ＞ peer 回報 ＞ 時間排程（AmbientSchedule，使用者開啟才算）。
/// 排程只在本機無感器且 AmbientSyncCore 沒有任何存活來源時接手；它是估計值，
/// **不廣播**——有真感器的 peer 一回來就立刻讓位。
///
/// 寫入路徑：一律經 DisplayManager.applyBrightness(_:toUUID:)（先寫 model、不廣播），
/// 因此 1 Hz poller 通常看不到落差；殘餘落差由 handleExternalBrightnessChange 對帳 ——
/// 與 lastAutoWritten 相近視為 DisplayServices 自身收斂（靜默吸收），
/// 否則視為使用者按了亮度鍵 → 差異值學習（不廣播）。
///
/// 同步語意：auto 受管的顯示器不發也不收 .brightness StateUpdate；
/// 跨機只同步環境基準（AmbientReport），各機套用自己的曲線與差異值。
@MainActor
@Observable
final class AutoBrightnessController {
    /// 本機平滑後的環境光（無感器為 nil）。
    private(set) var currentLux: Double?
    /// 目前生效的環境基準（本機感器或跟隨的 peer；無來源為 nil）。
    private(set) var baselineLux: Double?
    /// 基準來源 peerID（本機時等於 localPeerID；時間排程時為 scheduleSourceID）。
    private(set) var baselineSourceID: String?

    var hasLocalSensor: Bool { sensor.isAvailable }
    /// 目前基準是否來自時間排程（UI 文案用）。
    var isFollowingSchedule: Bool { baselineSourceID == Self.scheduleSourceID }

    /// 時間排程當基準時的來源識別；不是 peerID，不會撞到任何配對裝置。
    static let scheduleSourceID = "schedule"

    /// 所在地今天的日出日落；沒座標或極晝極夜為 nil（排程沿用手動時間）。
    var todaySunTimes: SolarCalculator.SunTimes? {
        guard let coordinate = location.coordinate else { return nil }
        return SolarCalculator.sunTimes(
            on: Date(), latitude: coordinate.latitude, longitude: coordinate.longitude
        )
    }

    /// 實際生效的排程：sunTracking 且算得出日出日落時，天亮天黑已換成今天的值。
    var resolvedSchedule: AmbientSchedule {
        let schedule = settings.ambientSchedule
        guard schedule.sunTracking, let sun = todaySunTimes else { return schedule }
        return schedule.applying(sun: sun)
    }

    /// Coordinator 注入：把本機感器回報廣播到 mesh。
    @ObservationIgnored var broadcastHandler: (@MainActor (AmbientReport) -> Void)?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private weak var displayManager: DisplayManager?
    @ObservationIgnored private let sensor: AmbientLightSensorClient
    @ObservationIgnored private let location: LocationProvider
    @ObservationIgnored private let localPeerID: String

    @ObservationIgnored private var smoother = LuxSmoother()
    @ObservationIgnored private var syncCore: AmbientSyncCore
    /// 近 24h 的本機 lux 樣本（committed 變化時記錄；光環境顧問統計用，不落地）。
    @ObservationIgnored private var luxHistory: [(micros: Int64, lux: Double)] = []
    /// 每台顯示器最後一次 auto 寫入的值（poller 對帳用）。
    @ObservationIgnored private var lastAutoWritten: [String: Double] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var rampTask: Task<Void, Never>?
    @ObservationIgnored private var lastReportSentMicros: Int64 = 0

    /// DisplayServices 收斂誤差容忍：poller 讀值與 lastAutoWritten 差距在此之內
    /// 視為我們自己的寫入還在收斂，不是使用者動作。
    private static let settleEpsilon = 0.02
    /// 感器輪詢間隔。
    private static let pollInterval: Duration = .seconds(2)
    /// 回報 keepalive 間隔（無變化也要發，供 follower 判斷來源存活）。
    private static let keepaliveMicros: Int64 = 15_000_000

    init(
        localPeerID: String,
        settings: SettingsStore,
        displayManager: DisplayManager,
        sensor: AmbientLightSensorClient,
        location: LocationProvider
    ) {
        self.localPeerID = localPeerID
        self.settings = settings
        self.displayManager = displayManager
        self.sensor = sensor
        self.location = location
        syncCore = AmbientSyncCore(localPeerID: localPeerID)
        syncCore.hasLocalSensor = sensor.isAvailable
    }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollSensor()
                try? await Task.sleep(for: Self.pollInterval)
            }
        }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.checkSourceStaleness()
            }
        }
        // 每次啟動重新定位一次：筆電搬家了要跟；Mac mini 上就是一次快取命中
        if !sensor.isAvailable, settings.ambientScheduleEnabled, settings.ambientSchedule.sunTracking {
            location.refresh()
        }
        refreshBaselineState()
    }

    // MARK: - 開關與查詢

    /// UI／TestHooks 切換總開關。
    func setAutoEnabled(_ enabled: Bool) {
        guard settings.autoBrightnessEnabled != enabled else { return }
        settings.autoBrightnessEnabled = enabled
        if enabled {
            pollSensor()
            reapplyTargets()
        } else {
            rampTask?.cancel()
            rampTask = nil
            lastAutoWritten = [:]
        }
    }

    /// 時間排程兜底開關（設定頁）。關掉時若正在用排程 → 基準清空、亮度維持現值。
    func setScheduleEnabled(_ enabled: Bool) {
        guard settings.ambientScheduleEnabled != enabled else { return }
        settings.ambientScheduleEnabled = enabled
        refreshBaselineState()
    }

    /// 排程參數變更（設定頁）；正在用排程時立即以新參數重算。
    /// 剛打開 sunTracking 會觸發定位（第一次會跳系統授權對話框）。
    func setSchedule(_ schedule: AmbientSchedule) {
        let wasTracking = settings.ambientSchedule.sunTracking
        settings.ambientSchedule = schedule
        if schedule.sunTracking, !wasTracking || location.coordinate == nil {
            location.refresh()
        }
        refreshBaselineState()
    }

    /// 該顯示器目前是否由 auto 管理（poller 與同步抑制的判斷依據）。
    func isAutoActive(for displayUUID: String) -> Bool {
        settings.autoBrightnessEnabled
            && !settings.ambientExcludedDisplays.contains(displayUUID)
            && baselineLux != nil
    }

    // MARK: - Poller／手動調整對帳

    /// Poller 發現實際亮度與 model 有落差時先問這裡。
    /// 回傳 true 表示已處理（poller 只需更新 model、不廣播）。
    func handleExternalBrightnessChange(uuid: String, actual: Double) -> Bool {
        guard isAutoActive(for: uuid) else { return false }
        if let written = lastAutoWritten[uuid], abs(actual - written) <= Self.settleEpsilon {
            // 自己寫入後 DisplayServices 內部平滑的殘值
            return true
        }
        learnOffset(uuid: uuid, manualValue: actual)
        return true
    }

    /// 使用者在 auto 中拖曳 slider → 學進該顯示器差異值（呼叫端負責套用與跳過廣播）。
    func learnOffsetFromManualSet(uuid: String, value: Double) {
        guard isAutoActive(for: uuid) else { return }
        learnOffset(uuid: uuid, manualValue: value)
    }

    // MARK: - 遠端基準

    /// 收到 peer 的環境光回報。
    func receiveRemoteBaseline(_ report: AmbientReport) {
        let effects = syncCore.receive(report, wallNowMicros: Self.wallNowMicros())
        applyEffects(effects)
    }

    /// Peer 斷線 → 立即放棄該來源（不等 45 秒靜默逾時）。
    func peerDisconnected(_ peerID: String) {
        let effects = syncCore.forgetOrigin(peerID, wallNowMicros: Self.wallNowMicros())
        applyEffects(effects)
        refreshBaselineState()
    }

    /// 新 session 建立時，若本機是感器來源，補發最新回報讓對方立即收斂。
    /// 回傳 nil 表示本機目前不是來源。
    func latestLocalReport() -> AmbientReport? {
        guard settings.autoBrightnessEnabled, sensor.isAvailable,
              let lux = smoother.committed
        else { return nil }
        return syncCore.localSample(lux: lux, wallNowMicros: Self.wallNowMicros())
    }

    // MARK: - 目標重算

    /// 曲線或差異值變更後重算所有受管顯示器。
    func reapplyTargets() {
        guard let baseline = baselineLux else { return }
        applyTargets(baseline: baseline)
    }

    /// 整機差異值（peer 經配置圖遠端調整）。
    func setDeviceOffset(_ offset: Double) {
        settings.ambientDeviceOffset = min(max(offset, -0.5), 0.5)
        reapplyTargets()
    }

    /// 單一顯示器差異值（配置圖／設定視窗）。
    func setDisplayOffset(_ offset: Double, for uuid: String) {
        settings.ambientDisplayOffsets[uuid] = min(max(offset, -0.5), 0.5)
        reapplyTargets()
    }

    /// 近 24h 本機環境光統計（光環境顧問 context 用）；無感器或無樣本為 nil。
    func recentLuxStats() -> LuxStats? {
        pruneLuxHistory(nowMicros: Self.wallNowMicros())
        let values = luxHistory.map(\.lux).sorted()
        guard !values.isEmpty else { return nil }
        return LuxStats(
            minLux: values.first!,
            medianLux: values[values.count / 2],
            maxLux: values.last!
        )
    }

    private func recordLuxSample(_ lux: Double, atMicros: Int64) {
        luxHistory.append((atMicros, lux))
        pruneLuxHistory(nowMicros: atMicros)
    }

    private func pruneLuxHistory(nowMicros: Int64) {
        let cutoff = nowMicros - 24 * 3600 * 1_000_000
        if let firstKept = luxHistory.firstIndex(where: { $0.micros >= cutoff }) {
            luxHistory.removeFirst(firstKept)
        } else if !luxHistory.isEmpty {
            luxHistory.removeAll()
        }
    }

    #if DEBUG
    /// TestHooks injectLux：改變假感器讀值並立即輪詢一次。
    func injectLux(_ value: Double) {
        sensor.setFakeLux(value)
        pollSensor()
    }
    #endif

    // MARK: - 私有

    private func pollSensor() {
        guard settings.autoBrightnessEnabled, sensor.isAvailable else { return }
        guard let raw = sensor.readLux() else { return }
        let nowMicros = Self.wallNowMicros()
        if let committed = smoother.ingest(lux: raw, nowMillis: nowMicros / 1000) {
            currentLux = committed
            recordLuxSample(committed, atMicros: nowMicros)
            let report = syncCore.localSample(lux: committed, wallNowMicros: nowMicros)
            baselineLux = committed
            baselineSourceID = localPeerID
            applyTargets(baseline: committed)
            broadcastHandler?(report)
            lastReportSentMicros = nowMicros
        } else if nowMicros - lastReportSentMicros >= Self.keepaliveMicros,
                  let committed = smoother.committed {
            // keepalive：值沒變也要讓 follower 知道來源還活著
            let report = syncCore.localSample(lux: committed, wallNowMicros: nowMicros)
            broadcastHandler?(report)
            lastReportSentMicros = nowMicros
        }
    }

    private func checkSourceStaleness() {
        guard !sensor.isAvailable || !settings.autoBrightnessEnabled else { return }
        let effects = syncCore.tick(wallNowMicros: Self.wallNowMicros())
        applyEffects(effects)
        refreshBaselineState()
    }

    private func applyEffects(_ effects: [AmbientSyncCore.Effect]) {
        for case let .followBaseline(lux, sourceID) in effects {
            baselineLux = lux
            baselineSourceID = sourceID
            if settings.autoBrightnessEnabled {
                applyTargets(baseline: lux)
            }
        }
    }

    /// 沒有存活的感器來源時的狀態同步：有開排程就退到排程（每次 tick 重算，
    /// 讓漸變隨時間走），否則清空基準、亮度維持現值不再跟隨。
    /// 有本機感器的機器永遠不會走到排程——pollSensor 自己就是來源。
    private func refreshBaselineState() {
        guard syncCore.currentBaseline() == nil else { return }
        guard !sensor.isAvailable, settings.ambientScheduleEnabled else {
            baselineLux = nil
            baselineSourceID = nil
            return
        }
        let lux = resolvedSchedule.lux(at: Date())
        baselineLux = lux
        baselineSourceID = Self.scheduleSourceID
        if settings.autoBrightnessEnabled {
            applyTargets(baseline: lux)
        }
    }

    /// 對所有受管顯示器計算目標並平滑過渡（5 步 × 100 ms）。
    private func applyTargets(baseline: Double) {
        guard let displayManager else { return }
        let base = settings.ambientCurve.map(lux: baseline)
        var targets: [(uuid: String, from: Double, to: Double)] = []
        for model in displayManager.displays where isAutoActive(for: model.uuid) {
            let target = AmbientCurve.applyOffsets(
                base: base,
                displayOffset: settings.ambientDisplayOffsets[model.uuid] ?? 0,
                deviceOffset: settings.ambientDeviceOffset
            )
            if abs(target - model.brightness) > 0.002 {
                targets.append((model.uuid, model.brightness, target))
            }
        }
        guard !targets.isEmpty else { return }

        rampTask?.cancel()
        let steps = 5
        rampTask = Task { [weak self] in
            for step in 1...steps {
                guard !Task.isCancelled, let self else { return }
                let fraction = Double(step) / Double(steps)
                for target in targets {
                    let value = target.from + (target.to - target.from) * fraction
                    self.lastAutoWritten[target.uuid] = value
                    self.displayManager?.applyBrightness(value, toUUID: target.uuid)
                }
                if step < steps {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
    }

    /// 手動值與目前 auto 目標的差 → 學進該顯示器差異值。
    private func learnOffset(uuid: String, manualValue: Double) {
        guard let baseline = baselineLux else { return }
        let base = settings.ambientCurve.map(lux: baseline)
        let offset = manualValue - base - settings.ambientDeviceOffset
        settings.ambientDisplayOffsets[uuid] = min(max(offset, -0.5), 0.5)
        lastAutoWritten[uuid] = manualValue
    }

    private static func wallNowMicros() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000)
    }
}
