import Foundation

/// 防睡眠模式。時間一律以 uptime 秒計（不受使用者改系統時鐘影響）。
public enum KeepAwakeMode: Sendable, Equatable, Codable, Hashable {
    case off
    /// 從啟用起算 N 秒後自動失效（選單提供 30m／1h）。
    case duration(seconds: Double)
    /// 無限期，直到使用者關掉。
    case indefinite
    /// 接著某台螢幕時才防睡眠——螢幕拔掉即自動失效
    /// （學 BetterDisplay 的 "Prevent sleep while connected for display"）。
    case whileDisplayConnected(uuid: String)
}

public enum KeepAwakePlanner {
    /// 現在是否應持有 IOPMAssertion。
    ///
    /// - Parameters:
    ///   - startedAt: 進入該模式時的 uptime；`.duration` 以此起算。nil 視為未啟用。
    ///   - connectedDisplayUUIDs: 目前在線的顯示器 UUID。
    public static func shouldHoldAssertion(
        mode: KeepAwakeMode,
        startedAt: Double?,
        now: Double,
        connectedDisplayUUIDs: Set<String>
    ) -> Bool {
        switch mode {
        case .off:
            return false
        case .indefinite:
            return startedAt != nil
        case let .duration(seconds):
            guard let startedAt else { return false }
            return now - startedAt < seconds
        case let .whileDisplayConnected(uuid):
            guard startedAt != nil else { return false }
            return connectedDisplayUUIDs.contains(uuid)
        }
    }

    /// 倒數剩餘秒數。只有 `.duration` 有值；無限期與螢幕綁定回 nil
    /// （UI 顯示「無限期」／「接著 XXX 時」而非數字）。
    public static func remainingSeconds(
        mode: KeepAwakeMode,
        startedAt: Double?,
        now: Double
    ) -> Double? {
        guard case let .duration(seconds) = mode, let startedAt else { return nil }
        return max(0, startedAt + seconds - now)
    }

    /// 遙控 command 的 value 編碼：0 = 關閉、負值 = 無限期、正值 = 秒數。
    /// 螢幕綁定模式是本機設定，不跨機遙控（對方的螢幕組合我們管不著）。
    public static func encode(_ mode: KeepAwakeMode) -> Double {
        switch mode {
        case .off: 0
        case .indefinite: -1
        case let .duration(seconds): seconds
        case .whileDisplayConnected: -1
        }
    }

    public static func decode(_ value: Double) -> KeepAwakeMode {
        if value < 0 { return .indefinite }
        if value == 0 { return .off }
        return .duration(seconds: value)
    }
}
