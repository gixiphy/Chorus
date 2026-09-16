/// 顯示模式描述（純資料）。不以暫時的 CoreGraphics mode ID 持久化或跨重連尋址。
public struct DisplayModeDescriptor: Sendable, Hashable, Codable, Equatable {
    public var logicalWidth: Int
    public var logicalHeight: Int
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// 更新率（Hz）。`0`＝未知／動態，不寫死成 60。
    public var refreshRate: Double
    /// 系統回報的 mode flags（僅供診斷；比對模式時不單獨依賴）。
    public var flags: UInt32

    public init(
        logicalWidth: Int,
        logicalHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Double,
        flags: UInt32 = 0
    ) {
        self.logicalWidth = max(0, logicalWidth)
        self.logicalHeight = max(0, logicalHeight)
        self.pixelWidth = max(0, pixelWidth)
        self.pixelHeight = max(0, pixelHeight)
        self.refreshRate = max(0, refreshRate)
        self.flags = flags
    }

    /// HiDPI：像素／邏輯兩軸比例皆 ≥ 1.5（常見 2×）；特殊比例回實際縮放。
    public var scaleFactor: Double {
        guard logicalWidth > 0, logicalHeight > 0 else { return 1 }
        let sx = Double(pixelWidth) / Double(logicalWidth)
        let sy = Double(pixelHeight) / Double(logicalHeight)
        return min(sx, sy)
    }

    public var isHiDPI: Bool { scaleFactor >= 1.5 }

    /// 精簡摘要，例如 `1920×1080 @ 60Hz` 或 `1512×982 HiDPI @ 120Hz`。
    public var summary: String {
        var parts = ["\(logicalWidth)×\(logicalHeight)"]
        if isHiDPI {
            let rounded = (scaleFactor * 10).rounded() / 10
            if abs(rounded - 2) < 0.05 {
                parts.append("HiDPI")
            } else {
                parts.append(String(format: "%.1f×", rounded))
            }
        }
        if refreshRate > 0 {
            let hz = refreshRate.rounded() == refreshRate
                ? String(format: "%.0fHz", refreshRate)
                : String(format: "%.2fHz", refreshRate)
            parts.append("@ \(hz)")
        }
        return parts.joined(separator: " ")
    }

    /// 比對兩份描述是否為同一模式（允許 refresh 浮點誤差）。
    public func matches(_ other: DisplayModeDescriptor, refreshEpsilon: Double = 0.5) -> Bool {
        logicalWidth == other.logicalWidth
            && logicalHeight == other.logicalHeight
            && pixelWidth == other.pixelWidth
            && pixelHeight == other.pixelHeight
            && abs(refreshRate - other.refreshRate) <= refreshEpsilon
    }
}

/// 使用者記住的顯示模式偏好（穩定身分＋模式描述；不存 mode ID）。
public struct DisplayModePreference: Sendable, Hashable, Codable, Equatable {
    public var displayUUID: String
    public var mode: DisplayModeDescriptor
    /// 重新連接時是否自動套用。第一版預設關閉。
    public var applyOnReconnect: Bool

    public init(displayUUID: String, mode: DisplayModeDescriptor, applyOnReconnect: Bool = false) {
        self.displayUUID = displayUUID
        self.mode = mode
        self.applyOnReconnect = applyOnReconnect
    }
}

/// 模式清單整理：去重保留不同更新率／縮放；標常用／HiDPI。
public enum DisplayModeCatalog {
    public struct Entry: Sendable, Hashable, Equatable {
        public var mode: DisplayModeDescriptor
        public var isCurrent: Bool
        public var isCommon: Bool

        public init(mode: DisplayModeDescriptor, isCurrent: Bool, isCommon: Bool) {
            self.mode = mode
            self.isCurrent = isCurrent
            self.isCommon = isCommon
        }
    }

    /// 去重鍵含寬高、像素、更新率（不可只看寬高）。
    public static func dedupe(_ modes: [DisplayModeDescriptor]) -> [DisplayModeDescriptor] {
        var seen: [DisplayModeDescriptor] = []
        for mode in modes {
            if seen.contains(where: { $0.matches(mode) }) { continue }
            seen.append(mode)
        }
        return seen
    }

    public static func entries(
        modes: [DisplayModeDescriptor],
        current: DisplayModeDescriptor?
    ) -> [Entry] {
        let unique = dedupe(modes)
        return unique.map { mode in
            let isCurrent = current.map { mode.matches($0) } ?? false
            let isCommon = mode.isHiDPI || isCurrent
            return Entry(mode: mode, isCurrent: isCurrent, isCommon: isCommon)
        }
        .sorted { lhs, rhs in
            if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
            if lhs.isCommon != rhs.isCommon { return lhs.isCommon }
            if lhs.mode.pixelWidth != rhs.mode.pixelWidth {
                return lhs.mode.pixelWidth > rhs.mode.pixelWidth
            }
            return lhs.mode.refreshRate > rhs.mode.refreshRate
        }
    }

    /// 在清單中找與偏好相符的模式；找不到回 nil（保留系統現況）。
    public static func resolve(
        preference: DisplayModeDescriptor,
        in modes: [DisplayModeDescriptor]
    ) -> DisplayModeDescriptor? {
        modes.first { $0.matches(preference) }
    }
}

/// 顯示模式試用交易的純狀態機（不含 CoreGraphics）。
public struct DisplayModeTransactionPolicy: Sendable, Equatable {
    public var confirmationDuration: Duration

    public init(confirmationDuration: Duration = .seconds(15)) {
        self.confirmationDuration = confirmationDuration
    }

    public enum Phase: String, Sendable, Hashable, Codable, Equatable {
        case idle
        case applying
        case awaitingConfirmation
        case committing
        case reverting
        case recoveryNeeded
    }

    public enum EndReason: String, Sendable, Hashable, Codable, Equatable {
        case confirmed
        case cancelled
        case timedOut
        case applyFailed
        case readbackMismatch
        case deviceRemoved
        case topologyChanged
        case externallyReplaced
        case quit
        case supersededByEmergency
    }

    public struct State: Sendable, Equatable {
        public var phase: Phase = .idle
        public var token: UInt64 = 0
        public var displayUUID: String?
        public var topologyGeneration: UInt64 = 0
        public var original: DisplayModeDescriptor?
        public var candidate: DisplayModeDescriptor?
        /// 確認期限（呼叫端提供的單調時鐘偏移；應含睡眠）。
        public var deadline: Duration?
        public var endReason: EndReason?

        public init() {}
    }

    public enum Action: Sendable, Equatable {
        case none
        case rejectedBusy
        case scheduleDeadline(at: Duration)
        case applyCandidate
        case revertToOriginal
        case finished(EndReason)
    }

    public func beginTrial(
        state: inout State,
        displayUUID: String,
        topologyGeneration: UInt64,
        original: DisplayModeDescriptor,
        candidate: DisplayModeDescriptor,
        now: Duration
    ) -> Action {
        guard state.phase == .idle || state.phase == .recoveryNeeded else {
            return .rejectedBusy
        }
        state.token &+= 1
        state.phase = .applying
        state.displayUUID = displayUUID
        state.topologyGeneration = topologyGeneration
        state.original = original
        state.candidate = candidate
        state.deadline = nil
        state.endReason = nil
        return .applyCandidate
    }

    /// 套用成功且讀回相符 → 進入確認倒數。
    public func applySucceeded(state: inout State, now: Duration) -> Action {
        guard state.phase == .applying else { return .none }
        state.phase = .awaitingConfirmation
        let deadline = now + confirmationDuration
        state.deadline = deadline
        return .scheduleDeadline(at: deadline)
    }

    public func applyFailed(state: inout State) -> Action {
        guard state.phase == .applying else { return .none }
        return finish(state: &state, reason: .applyFailed)
    }

    public func confirm(state: inout State) -> Action {
        guard state.phase == .awaitingConfirmation else { return .none }
        state.phase = .committing
        return finish(state: &state, reason: .confirmed)
    }

    public func cancel(state: inout State) -> Action {
        guard state.phase == .applying || state.phase == .awaitingConfirmation else { return .none }
        state.phase = .reverting
        return .revertToOriginal
    }

    public func deadlineReached(state: inout State, now: Duration) -> Action {
        guard state.phase == .awaitingConfirmation,
              let deadline = state.deadline,
              now >= deadline
        else { return .none }
        state.phase = .reverting
        return .revertToOriginal
    }

    public func revertFinished(state: inout State, restored: Bool, reason: EndReason? = nil) -> Action {
        guard state.phase == .reverting else { return .none }
        let end = reason ?? state.endReason ?? .timedOut
        if restored {
            return finish(state: &state, reason: end)
        }
        state.phase = .recoveryNeeded
        state.endReason = end
        // 保留 original／candidate 供 UI 列出替代
        state.deadline = nil
        return .finished(end)
    }

    public func noteExternalMode(
        state: inout State,
        actual: DisplayModeDescriptor
    ) -> Action {
        guard state.phase == .awaitingConfirmation || state.phase == .applying,
              let candidate = state.candidate,
              !actual.matches(candidate)
        else { return .none }
        // 外部已切走：不強行覆蓋
        return finish(state: &state, reason: .externallyReplaced)
    }

    public func abort(
        state: inout State,
        reason: EndReason
    ) -> Action {
        guard state.phase != .idle else { return .none }
        if state.phase == .awaitingConfirmation || state.phase == .applying {
            state.phase = .reverting
            state.endReason = reason
            return .revertToOriginal
        }
        return finish(state: &state, reason: reason)
    }

    private func finish(state: inout State, reason: EndReason) -> Action {
        let recovery = reason == .timedOut && state.phase == .reverting && false
        _ = recovery
        state.phase = .idle
        state.displayUUID = nil
        state.original = nil
        state.candidate = nil
        state.deadline = nil
        state.endReason = reason
        return .finished(reason)
    }
}
