import ChorusCore
import Foundation
import Testing
@testable import Chorus

/// 限時場景的生命週期（B7-1）。
///
/// 走假的執行端：controller 的責任是**什麼時候還原**，真正的套用與還原是
/// executor 的事（那條路由 E2E 覆蓋，因為它要真的讀硬體現值）。這裡守的是
/// 順序、時鐘、持久化與三條出口。
@MainActor
@Suite("限時場景 controller")
struct FocusSessionControllerTests {
    /// 記錄呼叫順序——「快照在套用之前」是這個功能唯一的承諾，
    /// 順序錯了不會報錯，只會讓還原變成「還原到套用之後」。
    @MainActor
    final class FakeExecutor: FocusExecuting {
        var snapshotToReturn = FocusSnapshot(requests: [
            ControlRequest(verb: .set, target: .system, property: .autoBrightness, value: "on"),
        ])
        var restoreResult: (restored: Int, failed: [String], retryable: [ControlRequest]) = (1, [], [])
        /// 補送時仍然失敗的那些（模擬 peer 又斷了）。
        var retryStillFailing: [ControlRequest] = []
        private(set) var calls: [String] = []
        private(set) var restored: [FocusSnapshot] = []
        private(set) var retried: [[ControlRequest]] = []

        func snapshot(forScene scene: ControlScene) -> FocusSnapshot {
            calls.append("snapshot:\(scene.name)")
            return snapshotToReturn
        }

        func applyScene(named name: String) -> [ControlResult] {
            calls.append("apply:\(name)")
            return [ControlResult(target: name, property: "autoBrightness", value: .bool(false))]
        }

        func restore(_ snapshot: FocusSnapshot) -> (restored: Int, failed: [String], retryable: [ControlRequest]) {
            calls.append("restore")
            restored.append(snapshot)
            return restoreResult
        }

        func retry(_ requests: [ControlRequest]) -> (restored: Int, stillFailing: [ControlRequest]) {
            calls.append("retry")
            retried.append(requests)
            return (requests.count - retryStillFailing.count, retryStillFailing)
        }

        /// 只看「這一步之後」發生了什麼時用。
        func resetLog() { calls.removeAll() }
    }

    @MainActor
    final class FakeNotifier: FocusNotifying {
        var authorizationResult = true
        private(set) var notified: [FocusOutcome] = []
        func requestAuthorization() async -> Bool { authorizationResult }
        func notifyEnded(_ outcome: FocusOutcome) { notified.append(outcome) }
    }

    private struct Fixture {
        let controller: FocusSessionController
        let executor: FakeExecutor
        let scenes: SceneStore
        let settings: SettingsStore
        let defaults: UserDefaults
        let notifier: FakeNotifier
    }

    private func makeFixture(sceneNames: [String] = ["工作"]) -> Fixture {
        let defaults = UserDefaults(suiteName: "focus-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let scenes = SceneStore(defaults: defaults)
        for name in sceneNames {
            scenes.save(ControlScene(name: name, requests: [
                ControlRequest(verb: .set, target: .system, property: .autoBrightness, value: "off"),
            ]))
        }
        let executor = FakeExecutor()
        // 固定基準時鐘：推進一律走 advanceClock，測試不受執行速度影響
        let controller = FocusSessionController(
            settings: settings, executor: executor, scenes: scenes,
            now: { Date(timeIntervalSince1970: 1_000) }
        )
        let notifier = FakeNotifier()
        controller.notifier = notifier
        return Fixture(controller: controller, executor: executor,
                       scenes: scenes, settings: settings, defaults: defaults,
                       notifier: notifier)
    }

    // MARK: - 開始

    @Test("快照在套用之前——順序反了就會還原到「套用之後」的狀態")
    func snapshotPrecedesApply() throws {
        let f = makeFixture()
        try f.controller.start(sceneName: "工作", duration: 1_500)
        #expect(f.executor.calls == ["snapshot:工作", "apply:工作"])
        #expect(f.controller.isRunning)
        #expect(f.controller.remainingSeconds == 1_500)
    }

    @Test("session 一開始就寫檔——崩潰後那條路依賴它")
    func persistsImmediately() throws {
        let f = makeFixture()
        try f.controller.start(sceneName: "工作", duration: 600)
        #expect(f.settings.focusSession?.sceneName == "工作")
        #expect(f.settings.focusSession?.snapshot.requests.count == 1)
    }

    @Test("場景名打錯不會把正在跑的那個一起還原掉")
    func unknownSceneKeepsRunningSession() throws {
        let f = makeFixture()
        try f.controller.start(sceneName: "工作", duration: 600)
        f.executor.resetLog()

        #expect(throws: ControlError.self) {
            try f.controller.start(sceneName: "不存在", duration: 600)
        }
        #expect(f.controller.isRunning)
        #expect(f.executor.calls.isEmpty)
    }

    @Test("時長必須是正的")
    func rejectsNonPositiveDuration() {
        let f = makeFixture()
        #expect(throws: ControlError.self) {
            try f.controller.start(sceneName: "工作", duration: 0)
        }
        #expect(!f.controller.isRunning)
    }

    // MARK: - 三條出口

    @Test("倒數走完：自動還原、記下結果、檔案清掉")
    func elapsedRestores() throws {
        let f = makeFixture()
        try f.controller.start(sceneName: "工作", duration: 600)

        f.controller.advanceClock(by: 599)
        #expect(f.controller.isRunning)
        #expect(f.controller.remainingSeconds == 1)

        f.controller.advanceClock(by: 1)
        #expect(!f.controller.isRunning)
        #expect(f.controller.lastOutcome?.reason == .elapsed)
        #expect(f.controller.lastOutcome?.restored == 1)
        #expect(f.executor.restored.count == 1)
        #expect(f.settings.focusSession == nil)
    }

    @Test("提前結束走同一條還原路，只有原因不同")
    func manualEndUsesSamePath() throws {
        let f = makeFixture()
        try f.controller.start(sceneName: "工作", duration: 600)
        f.controller.end(reason: .manual)

        #expect(f.controller.lastOutcome?.reason == .manual)
        #expect(f.executor.calls.last == "restore")
        #expect(f.settings.focusSession == nil)
    }

    @Test("結束 Chorus 一定還原（B3 的同一條態度）")
    func shutdownRestores() throws {
        let f = makeFixture()
        try f.controller.start(sceneName: "工作", duration: 600)
        f.controller.shutdown()

        #expect(f.controller.lastOutcome?.reason == .quit)
        #expect(f.executor.restored.count == 1)
    }

    @Test("沒有 session 時結束是 no-op，不會憑空還原一份空快照")
    func endWithoutSessionDoesNothing() {
        let f = makeFixture()
        f.controller.end(reason: .manual)
        #expect(f.executor.calls.isEmpty)
        #expect(f.controller.lastOutcome == nil)
    }

    // MARK: - 併發

    @Test("一次只有一個：再開一個會先把目前這個還原掉")
    func startingAnotherReplacesCurrent() throws {
        let f = makeFixture(sceneNames: ["工作", "會議"])
        try f.controller.start(sceneName: "工作", duration: 600)
        f.executor.resetLog()

        try f.controller.start(sceneName: "會議", duration: 300)
        // 先還原舊的，再快照＋套用新的——順序不對的話新場景的值會被
        // 舊場景的還原蓋掉
        #expect(f.executor.calls == ["restore", "snapshot:會議", "apply:會議"])
        #expect(f.controller.session?.sceneName == "會議")
        #expect(f.controller.remainingSeconds == 300)
    }

    // MARK: - 崩潰後接續

    @Test("重啟後未到期：接續倒數，不重跑場景")
    func resumeContinuesCountdown() throws {
        let f = makeFixture()
        try f.controller.start(sceneName: "工作", duration: 600)
        f.controller.advanceClock(by: 100)
        f.executor.resetLog()

        f.controller.simulateRelaunchForTesting()

        #expect(f.controller.isRunning)
        #expect(f.controller.remainingSeconds == 500)
        // 沒有 apply——場景早就套用過了，重跑一次會把使用者這段時間內
        // 手動改的東西再蓋一遍
        #expect(f.executor.calls.isEmpty)
    }

    @Test("重啟後已過期：立即還原，理由記成 relaunch")
    func resumeRestoresExpiredSession() throws {
        let f = makeFixture()
        try f.controller.start(sceneName: "工作", duration: 600)
        f.executor.resetLog()
        // 「App 沒跑的那段時間」——時鐘走過了 deadline
        f.controller.advanceClock(by: 700)
        // 上一行已經因為到期而還原了，改用一個沒有 tick 過的 controller
        // 重現真實形狀：檔案還在、記憶體是空的
        f.settings.focusSession = FocusSession(
            sceneName: "工作",
            startedAt: Date(timeIntervalSince1970: 0),
            deadline: Date(timeIntervalSince1970: 500),
            snapshot: f.executor.snapshotToReturn
        )
        f.executor.resetLog()

        f.controller.simulateRelaunchForTesting()

        #expect(!f.controller.isRunning)
        #expect(f.controller.lastOutcome?.reason == .relaunch)
        #expect(f.executor.calls == ["restore"])
        #expect(f.settings.focusSession == nil)
    }

    @Test("沒有存檔時接續是 no-op")
    func resumeWithoutStoredSession() {
        let f = makeFixture()
        f.controller.resumeIfNeeded()
        #expect(!f.controller.isRunning)
        #expect(f.executor.calls.isEmpty)
    }

    @Test("存檔跨 SettingsStore 重建仍讀得回來（真的落到 defaults）")
    func sessionSurvivesStoreRebuild() throws {
        let f = makeFixture()
        try f.controller.start(sceneName: "工作", duration: 600)

        let reloaded = SettingsStore(defaults: f.defaults)
        #expect(reloaded.focusSession?.sceneName == "工作")
        #expect(reloaded.focusSession?.deadline == f.controller.session?.deadline)
    }

    // MARK: - 結果

    @Test("不可還原的項目原樣帶進結果，不假裝還原了")
    func outcomeCarriesUnrestorable() throws {
        let f = makeFixture()
        f.executor.snapshotToReturn = FocusSnapshot(
            requests: [],
            unrestorable: ["ASUS VS207 的 input"]
        )
        f.executor.restoreResult = (0, [], [])
        try f.controller.start(sceneName: "工作", duration: 60)
        f.controller.end(reason: .manual)

        #expect(f.controller.lastOutcome?.unrestorable == ["ASUS VS207 的 input"])
        #expect(f.controller.lastOutcome?.restored == 0)
    }

    // MARK: - 通知與記憶（B7-3）

    @Test("通知開關預設關：到期不發")
    func noNotificationByDefault() throws {
        let f = makeFixture()
        #expect(!f.settings.focusNotifyOnEnd)
        try f.controller.start(sceneName: "工作", duration: 60)
        f.controller.advanceClock(by: 60)
        #expect(f.notifier.notified.isEmpty)
    }

    @Test("開了通知：倒數走完會發")
    func notifiesOnElapsed() throws {
        let f = makeFixture()
        f.settings.focusNotifyOnEnd = true
        try f.controller.start(sceneName: "工作", duration: 60)
        f.controller.advanceClock(by: 60)
        #expect(f.notifier.notified.count == 1)
        #expect(f.notifier.notified.first?.reason == .elapsed)
    }

    @Test("手動結束與被取代不發通知——那是使用者當下的動作，選單就看得到")
    func doesNotNotifyOnUserDrivenEnds() throws {
        let f = makeFixture(sceneNames: ["工作", "會議"])
        f.settings.focusNotifyOnEnd = true

        try f.controller.start(sceneName: "工作", duration: 600)
        f.controller.end(reason: .manual)
        #expect(f.notifier.notified.isEmpty)

        try f.controller.start(sceneName: "工作", duration: 600)
        try f.controller.start(sceneName: "會議", duration: 600)  // replaced
        #expect(f.notifier.notified.isEmpty)

        f.controller.shutdown()  // quit
        #expect(f.notifier.notified.isEmpty)
    }

    @Test("啟動時才還原的那一則會通知——使用者不在場時發生的事要講一次")
    func notifiesOnRelaunch() throws {
        let f = makeFixture()
        f.settings.focusNotifyOnEnd = true
        f.settings.focusSession = FocusSession(
            sceneName: "工作",
            startedAt: Date(timeIntervalSince1970: 0),
            deadline: Date(timeIntervalSince1970: 500),
            snapshot: f.executor.snapshotToReturn
        )
        f.controller.resumeIfNeeded()
        #expect(f.notifier.notified.first?.reason == .relaunch)
    }

    @Test("記住上次用過的時長（選單子選單的打勾靠它）")
    func remembersLastDuration() throws {
        let f = makeFixture()
        try f.controller.start(sceneName: "工作", duration: 2_700)
        #expect(f.settings.focusLastDuration == 2_700)
        // 跨 store 重建仍在
        #expect(SettingsStore(defaults: f.defaults).focusLastDuration == 2_700)
    }

    @Test("通知文案：全部還原 vs 有項目沒回來")
    func notificationCopy() {
        let clean = FocusOutcome(sceneName: "工作", reason: .elapsed, restored: 6,
                                 failed: [], unrestorable: [], endedAt: .now)
        #expect(FocusNotifier.body(for: clean) == "已還原 6 項")
        #expect(FocusNotifier.title(for: clean) == "「工作」結束")

        // 兩種「沒回來」在通知裡合成一個數字（選單那一行才分開講）
        let partial = FocusOutcome(sceneName: "工作", reason: .relaunch, restored: 5,
                                   failed: ["deviceUID:X：找不到"],
                                   unrestorable: ["ASUS 的 input"], endedAt: .now)
        #expect(FocusNotifier.body(for: partial) == "已還原 5 項，2 項未還原")
        #expect(FocusNotifier.title(for: partial) == "「工作」已於啟動時還原")
    }

    // MARK: - 跨機補送（B7-4）

    private var peerRestore: ControlRequest {
        ControlRequest(verb: .set, target: .app(bundleID: "com.tinyspeck.slackmacgap"),
                       property: .mute, value: "off", peer: "客廳")
    }

    @Test("對方離線的還原排進補送清單，並跨重啟保留")
    func offlinePeerRestoresQueue() throws {
        let f = makeFixture()
        f.executor.restoreResult = (1, ["客廳（跨機）：「客廳」目前沒有連線"], [peerRestore])
        try f.controller.start(sceneName: "工作", duration: 60)
        f.controller.end(reason: .manual)

        #expect(f.controller.pendingPeerRestores.count == 1)
        // 關掉 Chorus 不該讓對方的 Slack 永遠靜音
        #expect(SettingsStore(defaults: f.defaults).focusPendingPeerRestores.count == 1)
    }

    @Test("peer 連上就補送一次，成功後清單清空")
    func retryOnReconnect() throws {
        let f = makeFixture()
        f.executor.restoreResult = (1, ["客廳（跨機）：離線"], [peerRestore])
        try f.controller.start(sceneName: "工作", duration: 60)
        f.controller.end(reason: .manual)
        f.executor.resetLog()

        f.controller.retryPendingRestores()
        #expect(f.executor.retried.first?.count == 1)
        #expect(f.controller.pendingPeerRestores.isEmpty)
        #expect(SettingsStore(defaults: f.defaults).focusPendingPeerRestores.isEmpty)
    }

    @Test("補送又失敗就留著等下一次——不做無限重試，也不丟掉")
    func retryKeepsFailing() throws {
        let f = makeFixture()
        f.executor.restoreResult = (1, ["離線"], [peerRestore])
        try f.controller.start(sceneName: "工作", duration: 60)
        f.controller.end(reason: .manual)
        f.executor.retryStillFailing = [peerRestore]

        f.controller.retryPendingRestores()
        #expect(f.controller.pendingPeerRestores.count == 1)
    }

    @Test("沒有待補送時 retry 是 no-op（每次 peer 連上都會呼叫到）")
    func retryWithoutPendingIsNoOp() {
        let f = makeFixture()
        f.controller.retryPendingRestores()
        #expect(f.executor.calls.isEmpty)
    }

    @Test("使用者按放棄：清單清空，之後不再補送")
    func abandonPending() throws {
        let f = makeFixture()
        f.executor.restoreResult = (1, ["離線"], [peerRestore])
        try f.controller.start(sceneName: "工作", duration: 60)
        f.controller.end(reason: .manual)
        f.executor.resetLog()

        f.controller.abandonPendingRestores()
        #expect(f.controller.pendingPeerRestores.isEmpty)
        f.controller.retryPendingRestores()
        #expect(f.executor.calls.isEmpty)
    }

    @Test("啟動時把上次沒送成的補送清單讀回來")
    func pendingSurvivesRestart() throws {
        let f = makeFixture()
        f.executor.restoreResult = (1, ["離線"], [peerRestore])
        try f.controller.start(sceneName: "工作", duration: 60)
        f.controller.end(reason: .manual)

        let reloaded = FocusSessionController(
            settings: SettingsStore(defaults: f.defaults),
            executor: f.executor, scenes: f.scenes
        )
        #expect(reloaded.pendingPeerRestores.count == 1)
    }

    @Test("還原失敗的項目照實列出（裝置這 25 分鐘內被拔掉了）")
    func outcomeCarriesFailures() throws {
        let f = makeFixture()
        f.executor.restoreResult = (0, ["deviceUID:X：找不到符合的裝置"], [])
        try f.controller.start(sceneName: "工作", duration: 60)
        f.controller.end(reason: .manual)

        #expect(f.controller.lastOutcome?.failed.count == 1)
    }
}
