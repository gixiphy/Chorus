import ChorusCore
import CoreGraphics
import Foundation
import Observation

/// 全 App 至多一筆顯示模式試用交易。UI／緊急復原／結束路徑共用。
@MainActor
@Observable
final class DisplayConfigurationController {
    private(set) var phase: DisplayModeTransactionPolicy.Phase = .idle
    private(set) var activeDisplayUUID: String?
    private(set) var originalMode: DisplayModeDescriptor?
    private(set) var candidateMode: DisplayModeDescriptor?
    private(set) var confirmationDeadline: Date?
    private(set) var lastEndReason: DisplayModeTransactionPolicy.EndReason?
    private(set) var remainingSeconds: Double?
    private(set) var lastErrorMessage: String?

    @ObservationIgnored private var policy = DisplayModeTransactionPolicy()
    @ObservationIgnored private var state = DisplayModeTransactionPolicy.State()
    @ObservationIgnored private let modeClient: DisplayModeClient
    @ObservationIgnored private weak var displayManager: DisplayManager?
    @ObservationIgnored private var deadlineTask: Task<Void, Never>?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    /// 含睡眠的期限基準（Date）。
    @ObservationIgnored private let wallClock: () -> Date

    init(
        modeClient: DisplayModeClient = DisplayModeClient(),
        displayManager: DisplayManager? = nil,
        wallClock: @escaping () -> Date = Date.init
    ) {
        self.modeClient = modeClient
        self.displayManager = displayManager
        self.wallClock = wallClock
    }

    func attach(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    var isActive: Bool {
        phase != .idle && phase != .recoveryNeeded
    }

    /// 列舉模式（唯讀）。鏡像組仍可列，但標記不可寫。
    func catalog(for model: DisplayModel) -> (
        current: DisplayModeDescriptor?,
        entries: [DisplayModeCatalog.Entry],
        writable: Bool
    ) {
        let current = modeClient.currentMode(for: model.id)
        let modes = modeClient.availableModes(for: model.id)
        let writable = !modeClient.isMirrored(model.id) && !model.isPoweredOff
        return (current, DisplayModeCatalog.entries(modes: modes, current: current), writable)
    }

    /// 開始試用。進行中再呼叫回 false（busy）。
    @discardableResult
    func beginTrial(displayUUID: String, candidate: DisplayModeDescriptor) -> Bool {
        guard let model = displayManager?.displays.first(where: { $0.uuid == displayUUID }) else {
            lastErrorMessage = String(localized: "找不到顯示器")
            return false
        }
        guard !model.isPoweredOff else {
            lastErrorMessage = String(localized: "請先開啟螢幕再切換模式")
            return false
        }
        guard !modeClient.isMirrored(model.id) else {
            lastErrorMessage = String(localized: "鏡像顯示器第一版僅供檢視，不能切換模式")
            return false
        }
        guard let original = modeClient.currentMode(for: model.id) else {
            lastErrorMessage = String(localized: "無法讀取目前模式")
            return false
        }
        if original.matches(candidate) {
            lastErrorMessage = String(localized: "已是此模式")
            return false
        }

        let generation = displayManager?.topologyGeneration ?? 0
        let action = policy.beginTrial(
            state: &state,
            displayUUID: displayUUID,
            topologyGeneration: generation,
            original: original,
            candidate: candidate,
            now: .zero
        )
        publish()
        switch action {
        case .rejectedBusy:
            lastErrorMessage = String(localized: "已有進行中的模式試用，請先確認或還原")
            return false
        case .applyCandidate:
            return performApply(model: model, candidate: candidate)
        default:
            return false
        }
    }

    func confirm() {
        let action = policy.confirm(state: &state)
        handle(action, defaultReason: .confirmed)
        // 「保留」＝保留到 Chorus 結束（.forAppOnly 已生效，無需再寫系統）
        publish()
        clearDeadlineTasks()
    }

    func cancel() {
        let action = policy.cancel(state: &state)
        state.endReason = .cancelled
        handle(action, defaultReason: .cancelled)
    }

    /// 緊急復原／結束 App：終止試用並還原。
    func abortForEmergencyOrQuit(reason: DisplayModeTransactionPolicy.EndReason) {
        let action = policy.abort(state: &state, reason: reason)
        handle(action, defaultReason: reason)
    }

    /// 顯示器清單變更時呼叫：裝置移除或拓撲／外部模式變化。
    func displaysDidChange() {
        guard isActive || phase == .recoveryNeeded, let uuid = state.displayUUID else { return }
        guard let model = displayManager?.displays.first(where: { $0.uuid == uuid }) else {
            let action = policy.abort(state: &state, reason: .deviceRemoved)
            handle(action, defaultReason: .deviceRemoved)
            return
        }
        let generation = displayManager?.topologyGeneration ?? 0
        if generation != state.topologyGeneration, phase == .awaitingConfirmation || phase == .applying {
            let action = policy.abort(state: &state, reason: .topologyChanged)
            handle(action, defaultReason: .topologyChanged)
            return
        }
        if let actual = modeClient.currentMode(for: model.id) {
            let action = policy.noteExternalMode(state: &state, actual: actual)
            if case .finished = action {
                handle(action, defaultReason: .externallyReplaced)
            }
        }
    }

    /// 喚醒後先處理過期交易。
    func handleWake() {
        guard phase == .awaitingConfirmation, let deadline = confirmationDeadline else { return }
        if wallClock() >= deadline {
            state.endReason = .timedOut
            let action = policy.deadlineReached(
                state: &state,
                now: policy.confirmationDuration // force path via wall clock below
            )
            // 直接走還原：policy 的 monotonic 與 wall 可能不一致，以 Date 為準
            _ = action
            state.phase = .reverting
            publish()
            performRevert(reason: .timedOut)
        }
    }

    // MARK: - Private

    private func performApply(model: DisplayModel, candidate: DisplayModeDescriptor) -> Bool {
        lastErrorMessage = nil
        let result = OperationMetrics.shared.measure("display.mode.apply") {
            modeClient.apply(candidate, to: model.id)
        }
        switch result {
        case .success:
            let action = policy.applySucceeded(state: &state, now: .zero)
            // 期限用 wall clock（含睡眠）
            confirmationDeadline = wallClock().addingTimeInterval(15)
            state.deadline = .seconds(15)
            handle(action, defaultReason: nil)
            startDeadlineWatch()
            displayManager?.refreshModeSummaries()
            return true
        case .failure(let error):
            lastErrorMessage = describe(error)
            let action = policy.applyFailed(state: &state)
            handle(action, defaultReason: .applyFailed)
            // 讀回不符時嘗試還原
            if error == .readbackMismatch, let original = originalMode ?? state.original {
                _ = modeClient.apply(original, to: model.id)
            }
            return false
        }
    }

    private func performRevert(reason: DisplayModeTransactionPolicy.EndReason) {
        clearDeadlineTasks()
        guard let uuid = state.displayUUID ?? activeDisplayUUID,
              let model = displayManager?.displays.first(where: { $0.uuid == uuid }),
              let original = state.original ?? originalMode
        else {
            _ = policy.revertFinished(state: &state, restored: false, reason: reason)
            publish()
            return
        }
        let result = modeClient.apply(original, to: model.id)
        let restored: Bool
        switch result {
        case .success:
            restored = true
        case .failure:
            // 原模式不存在
            restored = false
            lastErrorMessage = String(localized: "無法還原到試用前的模式，請手動選擇")
        }
        _ = policy.revertFinished(state: &state, restored: restored, reason: reason)
        displayManager?.refreshModeSummaries()
        publish()
    }

    private func handle(
        _ action: DisplayModeTransactionPolicy.Action,
        defaultReason: DisplayModeTransactionPolicy.EndReason?
    ) {
        switch action {
        case .none, .rejectedBusy, .applyCandidate:
            publish()
        case .scheduleDeadline:
            publish()
        case .revertToOriginal:
            publish()
            performRevert(reason: defaultReason ?? state.endReason ?? .cancelled)
        case let .finished(reason):
            lastEndReason = reason
            clearDeadlineTasks()
            publish()
        }
    }

    private func startDeadlineWatch() {
        clearDeadlineTasks()
        deadlineTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                self.tickRemaining()
                guard let deadline = self.confirmationDeadline else { return }
                if self.wallClock() >= deadline {
                    self.state.endReason = .timedOut
                    self.state.phase = .reverting
                    self.publish()
                    self.performRevert(reason: .timedOut)
                    return
                }
            }
        }
    }

    private func tickRemaining() {
        guard let deadline = confirmationDeadline else {
            remainingSeconds = nil
            return
        }
        remainingSeconds = max(0, deadline.timeIntervalSince(wallClock()))
    }

    private func clearDeadlineTasks() {
        deadlineTask?.cancel()
        deadlineTask = nil
        tickTask?.cancel()
        tickTask = nil
        confirmationDeadline = nil
        remainingSeconds = nil
    }

    private func publish() {
        phase = state.phase
        activeDisplayUUID = state.displayUUID
        originalMode = state.original
        candidateMode = state.candidate
        lastEndReason = state.endReason
        if phase != .awaitingConfirmation {
            remainingSeconds = nil
        }
    }

    private func describe(_ error: DisplayModeClient.ApplyError) -> String {
        switch error {
        case .mirrored:
            return String(localized: "鏡像顯示器不能切換模式")
        case .modeNotFound:
            return String(localized: "系統已找不到此模式")
        case .configurationFailed:
            return String(localized: "套用顯示模式失敗")
        case .readbackMismatch:
            return String(localized: "套用後讀回不符，已中止")
        }
    }
}
