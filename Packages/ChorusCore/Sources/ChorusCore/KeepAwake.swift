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
    /// 某個 App 執行中才防睡眠——App 一結束即自動失效
    /// （學 Amphetamine 的 "app trigger"）。判斷依據是**行程還在**，
    /// 不是它在不在最前景：影片、算圖、會議都可能被切到背景。
    case whileAppRunning(bundleID: String)
}

public enum KeepAwakePlanner {
    /// 現在是否應持有 IOPMAssertion。
    ///
    /// - Parameters:
    ///   - startedAt: 進入該模式時的 uptime；`.duration` 以此起算。nil 視為未啟用。
    ///   - connectedDisplayUUIDs: 目前在線的顯示器 UUID。
    ///   - runningAppBundleIDs: 目前執行中的 App bundle ID。
    ///
    /// 兩個環境集合都不給預設值：漏傳等於「條件永遠不成立」，
    /// 而長亮失效是使用者最不想默默發生的事。
    public static func shouldHoldAssertion(
        mode: KeepAwakeMode,
        startedAt: Double?,
        now: Double,
        connectedDisplayUUIDs: Set<String>,
        runningAppBundleIDs: Set<String>
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
        case let .whileAppRunning(bundleID):
            guard startedAt != nil else { return false }
            return runningAppBundleIDs.contains(bundleID)
        }
    }

    /// 倒數剩餘秒數。只有 `.duration` 有值；無限期與螢幕／App 綁定回 nil
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
    /// 螢幕／App 綁定模式是本機設定，不跨機遙控
    /// （對方的螢幕組合與執行中的 App 我們管不著）。
    public static func encode(_ mode: KeepAwakeMode) -> Double {
        switch mode {
        case .off: 0
        case .indefinite: -1
        case let .duration(seconds): seconds
        case .whileDisplayConnected, .whileAppRunning: -1
        }
    }

    public static func decode(_ value: Double) -> KeepAwakeMode {
        if value < 0 { return .indefinite }
        if value == 0 { return .off }
        return .duration(seconds: value)
    }
}
