import AppKit
import ChorusCore
import Foundation
import Observation

/// `FocusSessionController` 需要執行端的三件事。
///
/// 抽成 protocol 的理由是**接縫**，不是測試替身：controller 的責任是
/// 「什麼時候還原」，真正的執行是 executor 的事，兩者之間只有這三個動詞。
/// 這條界線也是 DESIGN §2 的紀律——controller **不直接碰任何 manager**，
/// 套用與還原走的是與手動改設定完全同一條路。
@MainActor
protocol FocusExecuting: AnyObject {
    func snapshot(forScene scene: ControlScene) -> FocusSnapshot
    func applyScene(named name: String) -> [ControlResult]
    func restore(_ snapshot: FocusSnapshot) -> (restored: Int, failed: [String], retryable: [ControlRequest])
    /// 補送先前因為對方離線而沒送出去的還原（B7-4）。
    func retry(_ requests: [ControlRequest]) -> (restored: Int, stillFailing: [ControlRequest])
}

/// 一次限時場景結束後留下的結果。UI、通知與 SSE 事件講的都是這一份。
struct FocusOutcome: Equatable, Sendable {
    var sceneName: String
    var reason: FocusEndReason
    var restored: Int
    /// 還原失敗的項目（裝置已不在之類）。
    var failed: [String]
    /// 從一開始就還不回來的項目（輸入源、跨機）。
    var unrestorable: [String]
    var endedAt: Date
}

/// 限時場景（B7 專注模式）：套用場景 → 倒數 → 結束時原樣放回去。
///
/// **不是蕃茄鐘**——沒有休息提醒、沒有統計、沒有音效。做的是「場景 ＋ 時長
/// ＋ 結束自動還原」，也就是 B4 Scenes 與 B3 keep-awake 計時這兩塊既有積木
/// 的自然延伸。
///
/// 三條出口走**同一條** `end(reason:)`：倒數走完、使用者提前結束、結束
/// Chorus。第四條是崩潰——session 進行中就寫檔，下次啟動接續或立即還原。
@MainActor
@Observable
final class FocusSessionController {
    /// 進行中的 session。`nil` ＝ 沒有限時場景在跑。
    private(set) var session: FocusSession?
    /// 剩餘秒數。存成 property 而非 computed——選單列要每秒重繪倒數，
    /// 得是可觀察的變更（與 `KeepAwakeController.remainingSeconds` 同理）。
    private(set) var remainingSeconds: Double?
    /// 上一次結束的結果，供 UI 顯示「已還原 N 項」。
    private(set) var lastOutcome: FocusOutcome?
    /// 因為對方離線而還沒送出去的跨機還原（B7-4）。peer 一連上就補送一次。
    private(set) var pendingPeerRestores: [ControlRequest] = []

    /// SSE 事件流（`GET /v1/events` 與 `chorus listen`）。組裝順序上 hub 比
    /// controller 晚建立，所以是後設的——沒接上時只是不發事件，不影響還原。
    @ObservationIgnored var events: AutomationEventHub?

    /// 結束時的系統通知（B7-3）。預設關，開了才發——見 `settings.focusNotifyOnEnd`。
    @ObservationIgnored var notifier: (any FocusNotifying)?

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private unowned let executor: any FocusExecuting
    @ObservationIgnored private unowned let scenes: SceneStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
    /// 測試與 E2E 的時鐘推進量。正式路徑恆為 0，`currentDate` 因此完全等價。
    @ObservationIgnored private var clockOffset: TimeInterval = 0

    init(
        settings: SettingsStore,
        executor: any FocusExecuting,
        scenes: SceneStore,
        now: @escaping () -> Date = { Date() }
    ) {
        self.settings = settings
        self.executor = executor
        self.scenes = scenes
        self.now = now
        pendingPeerRestores = settings.focusPendingPeerRestores
    }

    private var currentDate: Date { now().addingTimeInterval(clockOffset) }

    var isRunning: Bool { session != nil }

    // MARK: - 開始

    /// 套用具名場景並開始倒數。
    ///
    /// 順序是刻意的：**先確認場景存在，再結束目前的 session**——場景名打錯
    /// 時不該把正在跑的那個一起還原掉。
    @discardableResult
    func start(sceneName: String, duration: TimeInterval) throws(ControlError) -> [ControlResult] {
        guard duration > 0 else {
            throw ControlError.badValue(
                "\(duration)", hint: "限時場景需要正的時長，例如 25m"
            )
        }
        guard let scene = scenes.scene(named: sceneName) else {
            throw ControlError.targetNotFound(sceneName, hint: scenes.scenes.isEmpty
                ? "還沒有任何場景"
                : "目前的場景：" + scenes.scenes.map(\.name).joined(separator: "、"))
        }

        // 一次只有一個 session：先把目前這個還原掉再開新的。這條規則就是
        // 第二步「蕃茄循環＝兩個限時場景接力」的地基——第一版不做循環，
        // 但路先鋪平。
        if session != nil { end(reason: .replaced) }

        // 快照要在套用**之前**取——這是整個功能唯一的承諾
        let snapshot = executor.snapshot(forScene: scene)
        let applied = executor.applyScene(named: scene.name)
        let started = currentDate
        session = FocusSession(
            sceneName: scene.name,
            startedAt: started,
            deadline: started.addingTimeInterval(duration),
            snapshot: snapshot,
            applied: applied
        )
        settings.focusLastDuration = duration
        persist()
        refreshRemaining()
        startTicking()
        events?.publish(kind: "focus", payload: [
            "phase": "started",
            "scene": scene.name,
            "deadline": session?.deadline.formatted(.iso8601) ?? "",
            "restorable": snapshot.restorableCount,
        ])
        return applied
    }

    // MARK: - 結束（三條出口共用）

    func end(reason: FocusEndReason) {
        guard let session else { return }
        // 先清掉狀態再還原：還原會走 executor → manager，過程中的變更通知
        // 可能繞回來（自動亮度、裝置事件），此時 session 必須已經不在，
        // 否則 tick 會重入、還原做兩次。
        self.session = nil
        remainingSeconds = nil
        stopTicking()
        persist()

        let outcome = executor.restore(session.snapshot)
        // 對方離線的那幾條不是壞掉，只是現在送不到——排進補送清單
        if !outcome.retryable.isEmpty {
            pendingPeerRestores += outcome.retryable
            settings.focusPendingPeerRestores = pendingPeerRestores
        }
        lastOutcome = FocusOutcome(
            sceneName: session.sceneName,
            reason: reason,
            restored: outcome.restored,
            failed: outcome.failed,
            unrestorable: session.snapshot.unrestorable,
            endedAt: currentDate
        )
        // `unrestored` 把兩種「沒回來」合成一份：訂閱者要的是「哪些東西
        // 現在還停在場景狀態」，不需要分辨那是還原失敗還是從一開始就還不回來
        // 通知只發「使用者可能不在看」的那兩種結束（見 deservesNotification）。
        // 開關預設關；關著時選單列徽章、選單那一行與 SSE 事件仍看得出來
        if settings.focusNotifyOnEnd, reason.deservesNotification, let lastOutcome {
            notifier?.notifyEnded(lastOutcome)
        }
        events?.publish(kind: "focus", payload: [
            "phase": "ended",
            "scene": session.sceneName,
            "reason": reason.rawValue,
            "restored": outcome.restored,
            "unrestored": outcome.failed + session.snapshot.unrestorable,
        ])
    }

    /// App 要結束了。與 B3「結束 Chorus 一定還原」同態度：使用者不該因為
    /// 關掉 Chorus 而被留在「Slack 靜音、螢幕 30%」的狀態。
    func shutdown() {
        end(reason: .quit)
        stopTicking()
    }

    // MARK: - 倒數

    /// 一拍。到期就走 `end`，否則只更新剩餘秒數。
    func tick() {
        guard let session else { return }
        if FocusPlanner.isExpired(session: session, now: currentDate) {
            end(reason: .elapsed)
        } else {
            refreshRemaining()
        }
    }

    /// 推進測試時鐘並立刻結算。單元測試與 E2E 共用同一個入口——
    /// 沒有人需要真的等 25 分鐘。
    func advanceClock(by seconds: TimeInterval) {
        clockOffset += seconds
        tick()
    }

    private func refreshRemaining() {
        remainingSeconds = session.map { FocusPlanner.remainingSeconds(session: $0, now: currentDate) }
    }

    private func startTicking() {
        installWakeObserver()
        guard tickTask == nil else { return }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.session != nil else { return }
                self.tick()
            }
        }
    }

    private func stopTicking() {
        tickTask?.cancel()
        tickTask = nil
        removeWakeObserver()
    }

    /// 睡醒時立刻結算，不等下一秒的 tick。
    ///
    /// 時間基準是 wall clock（`FocusSession.startedAt` 的註解），所以闔上
    /// 筆電 10 分鐘再打開，deadline 很可能已經過了——那一刻就該還原，
    /// 而不是讓使用者看著一個早該結束的倒數再走一秒。
    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppStateRegistry.focus?.tick()
            }
        }
    }

    private func removeWakeObserver() {
        guard let wakeObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        self.wakeObserver = nil
    }

    // MARK: - 持久化與啟動接續

    private func persist() {
        settings.focusSession = session
    }

    /// 上次沒有正常結束時，把 session 接回來。
    ///
    /// **必須等各 manager 列舉完才呼叫**：顯示器與音訊裝置還沒到齊時，
    /// 還原會誤判「裝置已不在」，把整組東西留在場景狀態。
    ///
    /// 已過期就立即還原並留下 outcome（選單會顯示「上次的『工作』已於啟動時
    /// 還原」）；還沒過期就接續倒數。**不問使用者**——問了就要等，
    /// 而等的期間狀態是錯的。
    func resumeIfNeeded() {
        guard session == nil, let stored = settings.focusSession else { return }
        session = stored
        if FocusPlanner.isExpired(session: stored, now: currentDate) {
            end(reason: .relaunch)
        } else {
            refreshRemaining()
            startTicking()
        }
    }

    // MARK: - 跨機補送（B7-4）

    /// peer 連上了，把欠它的還原補送一次。
    ///
    /// **不做無限重試、也不設時限**：peer 回來就送、使用者說算了就算了
    /// （`abandonPendingRestores`），兩個出口都明確。定時輪詢一個可能
    /// 半年不開機的 Mac 只是在製造背景雜訊。
    func retryPendingRestores() {
        guard !pendingPeerRestores.isEmpty else { return }
        let result = executor.retry(pendingPeerRestores)
        guard result.restored > 0 || result.stillFailing.count != pendingPeerRestores.count else { return }
        pendingPeerRestores = result.stillFailing
        settings.focusPendingPeerRestores = pendingPeerRestores
    }

    /// 使用者按「放棄」：不再嘗試把那些值送回去。
    func abandonPendingRestores() {
        guard !pendingPeerRestores.isEmpty else { return }
        pendingPeerRestores = []
        settings.focusPendingPeerRestores = []
    }

    /// 收掉「上次結束」那一行（選單上的 ✕）。
    func dismissLastOutcome() {
        lastOutcome = nil
    }

    #if DEBUG
    /// E2E：模擬「上次沒有正常結束」——丟掉記憶體裡的 session（檔案留著），
    /// 再走一次啟動接續。與真的重啟 App 走的是同一條 `resumeIfNeeded`，
    /// 省掉在測試裡重啟行程與重新等 dump 的成本。
    /// 推進過的測試時鐘**保留**：否則 relaunch 後 deadline 判斷會回到現在。
    func simulateRelaunchForTesting() {
        session = nil
        remainingSeconds = nil
        stopTicking()
        resumeIfNeeded()
    }
    #endif

    /// AppState 組裝完呼叫。延遲是為了讓顯示器與音訊裝置列舉完成
    /// （見 `resumeIfNeeded`），不是為了等 UI。
    func scheduleResume(after delay: Duration = .seconds(2)) {
        guard settings.focusSession != nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.resumeIfNeeded()
        }
    }
}
