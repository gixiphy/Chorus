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
@MainActor
@Observable
final class AgentIdleBlanker {
    private(set) var isBlanked = false

    @ObservationIgnored private let displays: any IdleBlankDisplayControlling
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var thresholdSeconds = Double(KeepAwakeAgentIdleMinutes.default.rawValue * 60)
    @ObservationIgnored private var agentModeActive = false
    @ObservationIgnored private var holdingAssertion = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private let idleSeconds: () -> Double

    /// `kCGAnyInputEventType`（`~0`）：滑鼠、鍵盤、平板等任一輸入都算。
    private static let anyInputEvent = CGEventType(rawValue: ~UInt32(0))!

    init(
        displays: any IdleBlankDisplayControlling,
        idleSeconds: @escaping () -> Double = {
            CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: AgentIdleBlanker.anyInputEvent
            )
        }
    ) {
        self.displays = displays
        self.idleSeconds = idleSeconds
    }

    /// 套用設定。值沒變就不重啟計時器（控制器每次 reevaluate 都會叫到）。
    func configure(enabled: Bool, minutes: KeepAwakeAgentIdleMinutes) {
        let threshold = Double(minutes.rawValue * 60)
        guard self.enabled != enabled || thresholdSeconds != threshold else { return }
        self.enabled = enabled
        thresholdSeconds = threshold
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
        if wasBlanked {
            displays.restoreIdleBlank()
            isBlanked = false
        }
    }

    /// 測試縫：立刻依目前狀態跑一輪決策。
    func evaluateForTesting() { evaluate() }

    private func evaluate() {
        let decision = AgentIdleBlankPolicy.decide(
            enabled: enabled,
            agentModeActive: agentModeActive,
            holdingAssertion: holdingAssertion,
            idleSeconds: idleSeconds(),
            thresholdSeconds: thresholdSeconds,
            isBlanked: isBlanked
        )
        switch decision {
        case .stay:
            break
        case .blank:
            _ = displays.blankForIdle()
            isBlanked = true
            updateTick()
        case .restore:
            displays.restoreIdleBlank()
            isBlanked = false
            updateTick()
        }
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
