import AppKit
import ChorusCore
import CoreGraphics
import Foundation
import Observation

/// 閒置熄屏對 DisplayManager 的最小介面；測試可注入假實作。
@MainActor
protocol IdleBlankDisplayControlling: AnyObject {
    @discardableResult
    func blankForIdle() -> Set<String>
    func restoreIdleBlank()
}

extension DisplayManager: IdleBlankDisplayControlling {}

/// Agent 模式閒置熄屏。持有 assertion 且使用者閒置 N 分鐘後關掉螢幕；
/// 一有輸入、agent 收工、離開 agent 模式或 App 結束就恢復。
///
/// 預設關閉——3644f2c 刻意讓 agent 模式擋螢幕待機，有些人就是要看著畫面。
/// 熄屏前會看媒體／前景全螢幕，以及其他程序的
/// `PreventUserIdleDisplaySleep`；未知或讀取失敗時保守不熄。
@MainActor
@Observable
final class AgentIdleBlanker {
    /// 接近門檻多少秒內才查外部 assertion（避免每 tick 打 powerd）。
    static let foreignAssertionNearThresholdSeconds: Double = 60
    /// 已查過的外部 assertion 快取存活時間。
    static let foreignAssertionCacheTTL: Duration = .seconds(60)

    private(set) var isBlanked = false

    @ObservationIgnored private let displays: any IdleBlankDisplayControlling
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var thresholdSeconds = Double(KeepAwakeAgentIdleMinutes.default.rawValue * 60)
    @ObservationIgnored private var agentModeActive = false
    @ObservationIgnored private var holdingAssertion = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private let idleSeconds: () -> Double
    @ObservationIgnored private let mediaOrFullscreen: () -> IdleBlankSignal
    @ObservationIgnored private let foreignDisplayAssertion: () -> IdleBlankSignal

    @ObservationIgnored private var cachedForeignAssertion: IdleBlankSignal?
    @ObservationIgnored private var lastForeignQueryAt: ContinuousClock.Instant?

    /// Production：合併活動秒數＋公開 API 保護讀取器。
    init(displays: any IdleBlankDisplayControlling) {
        self.displays = displays
        self.idleSeconds = { IdleActivityReaders.combinedIdleSeconds() }
        self.mediaOrFullscreen = { IdleBlankProtectionReaders.foregroundFullscreen() }
        self.foreignDisplayAssertion = { IdleBlankProtectionReaders.foreignDisplaySleepAssertion() }
    }

    /// 測試／自訂讀取器。未覆寫的保護訊號預設 inactive（不擋既有測試）。
    init(
        displays: any IdleBlankDisplayControlling,
        idleSeconds: @escaping () -> Double,
        mediaOrFullscreen: @escaping () -> IdleBlankSignal = { .inactive },
        foreignDisplayAssertion: @escaping () -> IdleBlankSignal = { .inactive }
    ) {
        self.displays = displays
        self.idleSeconds = idleSeconds
        self.mediaOrFullscreen = mediaOrFullscreen
        self.foreignDisplayAssertion = foreignDisplayAssertion
    }

    /// 套用設定。值沒變就不重啟計時器（控制器每次 reevaluate 都會叫到）。
    func configure(enabled: Bool, minutes: KeepAwakeAgentIdleMinutes) {
        let threshold = Double(minutes.rawValue * 60)
        guard self.enabled != enabled || thresholdSeconds != threshold else { return }
        self.enabled = enabled
        thresholdSeconds = threshold
        invalidateForeignAssertionCache()
        evaluate()
        updateTick()
    }

    /// Agent 模式進出與 assertion 持有狀態變更時呼叫。
    func update(agentModeActive: Bool, holdingAssertion: Bool) {
        guard self.agentModeActive != agentModeActive || self.holdingAssertion != holdingAssertion else {
            return
        }
        self.agentModeActive = agentModeActive
        self.holdingAssertion = holdingAssertion
        running = agentModeActive
        invalidateForeignAssertionCache()
        evaluate()
        updateTick()
    }

    /// App 結束／離開長亮：恢復螢幕並停掉輪詢。
    func stop() {
        let wasBlanked = isBlanked
        running = false
        agentModeActive = false
        holdingAssertion = false
        tickTask?.cancel()
        tickTask = nil
        invalidateForeignAssertionCache()
        if wasBlanked {
            displays.restoreIdleBlank()
            isBlanked = false
            logIdleTransition(restore: true, reason: "stop")
        }
    }

    /// 測試縫：立刻依目前狀態跑一輪決策。
    func evaluateForTesting() { evaluate() }

    /// 測試縫：把上次外部 assertion 查詢時間往前推，模擬 TTL 過期。
    func ageForeignAssertionCacheForTesting(by duration: Duration) {
        lastForeignQueryAt = lastForeignQueryAt.map { $0 - duration }
    }

    private func evaluate() {
        let idle = idleSeconds()
        let protection = AgentIdleBlankProtection(
            foreignDisplaySleepAssertion: resolveForeignAssertion(idleSeconds: idle),
            mediaOrFullscreen: mediaOrFullscreen()
        )
        let decision = AgentIdleBlankPolicy.decide(
            enabled: enabled,
            agentModeActive: agentModeActive,
            holdingAssertion: holdingAssertion,
            idleSeconds: idle,
            thresholdSeconds: thresholdSeconds,
            isBlanked: isBlanked,
            protection: protection
        )
        switch decision {
        case .stay:
            break
        case .blank:
            _ = displays.blankForIdle()
            isBlanked = true
            logIdleTransition(restore: false, reason: "idle")
            updateTick()
        case .restore:
            displays.restoreIdleBlank()
            isBlanked = false
            logIdleTransition(restore: true, reason: restoreReason(idle: idle, protection: protection))
            updateTick()
        }
    }

    private func resolveForeignAssertion(idleSeconds: Double) -> IdleBlankSignal {
        let now = ContinuousClock.now
        if shouldQueryForeignAssertion(idleSeconds: idleSeconds, now: now) {
            let value = foreignDisplayAssertion()
            cachedForeignAssertion = value
            lastForeignQueryAt = now
            return value
        }
        return cachedForeignAssertion ?? .inactive
    }

    private func shouldQueryForeignAssertion(idleSeconds: Double, now: ContinuousClock.Instant) -> Bool {
        guard let last = lastForeignQueryAt, cachedForeignAssertion != nil else {
            // 無快取：已熄屏或接近門檻才查；無效 idle 不會熄屏，仍查一次記未知。
            return isBlanked || !AgentIdleBlankPolicy.isValidIdleSeconds(idleSeconds)
                || idleSeconds >= max(0, thresholdSeconds - Self.foreignAssertionNearThresholdSeconds)
        }
        let expired = now - last >= Self.foreignAssertionCacheTTL
        // 已熄屏：不每 500ms 打 powerd，但仍按 TTL 低頻重驗，媒體開始時才能恢復。
        if isBlanked { return expired }
        guard AgentIdleBlankPolicy.isValidIdleSeconds(idleSeconds) else { return false }
        let near =
            idleSeconds >= max(0, thresholdSeconds - Self.foreignAssertionNearThresholdSeconds)
        return near && expired
    }

    private func invalidateForeignAssertionCache() {
        cachedForeignAssertion = nil
        lastForeignQueryAt = nil
    }

    private func restoreReason(idle: Double, protection: AgentIdleBlankProtection) -> String {
        if AgentIdleBlankPolicy.isValidIdleSeconds(idle),
           idle < AgentIdleBlankPolicy.activityResumeSeconds
        {
            return "activity"
        }
        if protection.mediaOrFullscreen == .active { return "media" }
        if protection.foreignDisplaySleepAssertion == .active { return "foreignAssertion" }
        return "disarm"
    }

    private func logIdleTransition(restore: Bool, reason: String) {
        let event = restore ? KeepAwakeLogEvent.idleRestore : KeepAwakeLogEvent.idleBlank
        ChorusLog.display.event(
            event,
            level: .notice,
            fields: ["reason": reason]
        )
    }

    private func updateTick() {
        tickTask?.cancel()
        tickTask = nil
        let armed = enabled && agentModeActive && holdingAssertion
        guard running, armed || isBlanked else { return }
        let interval: Duration = isBlanked ? .milliseconds(500) : .seconds(10)
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard !Task.isCancelled, let self else { return }
                self.evaluate()
            }
        }
    }
}
