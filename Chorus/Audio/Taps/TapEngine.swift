import ChorusCore
import Foundation
import Observation

/// Process tap 引擎（B6-1 基礎設施）。
///
/// 職責：權限流程（DESIGN §1.2 定稿）、tap session 生命週期、健康判讀、
/// 預設輸出變更時搬家。**per-app 的 UI 與持久化是 B6-2**——這裡只提供
/// tap(bundleID:)／untap 的機制與 DEBUG 入口。
///
/// 權限流程（沒有任何 API 能查詢，只能靠行為判讀）：
/// 啟用 → captureOnly 探測 session（AudioDeviceStart 觸發系統對話框）→
/// 每秒餵 TapHealthMonitor → healthy＝權限有、收探測進 active／
/// denied＝收探測進 denied、引導去系統設定。
@MainActor
@Observable
final class TapEngine {
    enum State: Equatable {
        case off
        /// 探測中。權限被拒**不會有任何錯誤**，只能等健康判讀；
        /// 系統無聲時判不了——UI 要提示「播放任何聲音以完成確認」。
        case probing
        /// 權限確認、基礎設施就緒（探測已收掉，沒有常駐 tap——
        /// §2.3 規則 2：沒被調整的 App 一個 tap 都不建）。
        case active
        /// 判定權限缺失（連續「發聲卻全零」）。
        case denied
        case failed(String)
    }

    private(set) var state: State = .off
    /// 進行中的 per-app session（bundleID → session）。
    private(set) var tappedBundles: [String] = []
    /// 探測的即時統計（設定頁顯示用）。
    private(set) var probeStats = TapSessionStats()

    @ObservationIgnored private let backend: any TapBackend
    @ObservationIgnored let registry: AudioProcessRegistry
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private var probeSession: (any TapSession)?
    @ObservationIgnored private var sessions: [String: any TapSession] = [:]
    @ObservationIgnored private var monitor = TapHealthMonitor()
    @ObservationIgnored private var lastProbeStats = TapSessionStats()
    @ObservationIgnored private var tickTask: Task<Void, Never>?

    init(backend: any TapBackend, registry: AudioProcessRegistry, settings: SettingsStore) {
        self.backend = backend
        self.registry = registry
        self.settings = settings
        backend.setDefaultOutputChangedHandler { [weak self] in
            self?.defaultOutputChanged()
        }
    }

    /// App 啟動時呼叫：上次已啟用就直接重新探測（TCC 已給過的話
    /// 幾秒內就會轉 active，沒有對話框）。
    func start() {
        if settings.audioTapsEnabled {
            beginProbe()
        }
    }

    func setEnabled(_ enabled: Bool) {
        settings.audioTapsEnabled = enabled
        if enabled {
            beginProbe()
        } else {
            shutdownSessions()
            state = .off
        }
    }

    /// denied 後使用者到系統設定改了權限 → 重試。
    func retryPermission() {
        guard settings.audioTapsEnabled else { return }
        beginProbe()
    }

    // MARK: - per-app tap（機制；UI 與持久化屬 B6-2）

    func tap(bundleID: String) {
        guard state == .active, sessions[bundleID] == nil else { return }
        guard let outputUID = backend.defaultOutputDeviceUID() else {
            state = .failed("找不到預設輸出裝置")
            return
        }
        do {
            sessions[bundleID] = try backend.startPlaythroughSession(
                bundleID: bundleID, outputDeviceUID: outputUID
            )
            tappedBundles = Array(sessions.keys).sorted()
        } catch {
            // 單一 App 失敗不拖垮引擎（CrashGuard 的行為教訓）：
            // 記錄並繼續，其他 session 與裝置功能不受影響
            state = .failed("無法接管 \(bundleID)：\(error)")
        }
    }

    func untap(bundleID: String) {
        sessions.removeValue(forKey: bundleID)?.stop()
        tappedBundles = Array(sessions.keys).sorted()
        if case .failed = state { state = .active }
    }

    func setGain(_ gain: Float, bundleID: String) {
        sessions[bundleID]?.setGain(gain)
    }

    func setMuted(_ muted: Bool, bundleID: String) {
        sessions[bundleID]?.setMuted(muted)
    }

    // MARK: - 探測與健康判讀

    private func beginProbe() {
        shutdownSessions()
        monitor.reset()
        lastProbeStats = TapSessionStats()
        probeStats = TapSessionStats()
        registry.refresh()
        guard let outputUID = backend.defaultOutputDeviceUID() else {
            state = .failed("找不到預設輸出裝置")
            return
        }
        do {
            let excluded = registry.ownProcessObjectID.map { [$0] } ?? []
            probeSession = try backend.startProbeSession(
                outputDeviceUID: outputUID, excludingProcessObjects: excluded
            )
            state = .probing
            startTicking()
        } catch {
            state = .failed("探測啟動失敗：\(error)")
        }
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.healthTick()
                if self.state != .probing { return }
            }
        }
    }

    /// 每秒一次：把統計差分餵給 TapHealthMonitor。
    /// internal 而非 private——單元測試直接呼叫，不用等計時器。
    func healthTick() {
        guard state == .probing, let probeSession else { return }
        registry.refresh()
        let current = probeSession.stats
        probeStats = current
        let delta = current - lastProbeStats
        lastProbeStats = current
        let verdict = monitor.record(TapHealthMonitor.Window(
            callbacks: delta.callbacks,
            nonZeroCallbacks: delta.nonZeroCallbacks,
            anySourceAudible: registry.anyOtherProcessAudible
        ))
        switch verdict {
        case .healthy:
            stopProbe()
            state = .active
        case .permissionDenied:
            stopProbe()
            state = .denied
        case .undetermined:
            break
        }
    }

    // MARK: - 裝置變更與收尾

    /// 預設輸出換了：所有 playthrough session 搬到新裝置。
    /// 舊 session 指向的裝置可能已拔除，先收再重建。
    private func defaultOutputChanged() {
        guard !sessions.isEmpty, let outputUID = backend.defaultOutputDeviceUID() else { return }
        let bundles = Array(sessions.keys)
        for (_, session) in sessions { session.stop() }
        sessions = [:]
        for bundle in bundles {
            if let session = try? backend.startPlaythroughSession(
                bundleID: bundle, outputDeviceUID: outputUID
            ) {
                sessions[bundle] = session
            }
        }
        tappedBundles = Array(sessions.keys).sorted()
    }

    private func stopProbe() {
        probeSession?.stop()
        probeSession = nil
        tickTask?.cancel()
        tickTask = nil
    }

    private func shutdownSessions() {
        stopProbe()
        for (_, session) in sessions { session.stop() }
        sessions = [:]
        tappedBundles = []
    }
}
