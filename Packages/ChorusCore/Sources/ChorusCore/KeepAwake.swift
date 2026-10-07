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
    /// 有 AI agent 在工作時才防睡眠——agent 收工即自動失效
    /// （學 Orca 的 "Keep computer awake: Agent"）。
    ///
    /// 同時保持螢幕與系統清醒，避免工作被待機中斷。見 `assertionPlan`。
    case whileAgentsWorking
    /// 整機 CPU／GPU／網路持續高負載時才防睡眠——負載消退後自動解除。
    case whileSystemBusy
}

/// 持有期間各擋哪一種待機。Agent 模式同時擋螢幕與系統待機，
/// 其餘模式一定擋螢幕待機、系統待機看設定。
public struct KeepAwakeAssertionPlan: Sendable, Equatable, Hashable {
    public let preventsDisplaySleep: Bool
    public let preventsSystemSleep: Bool

    public init(preventsDisplaySleep: Bool, preventsSystemSleep: Bool) {
        self.preventsDisplaySleep = preventsDisplaySleep
        self.preventsSystemSleep = preventsSystemSleep
    }
}

public enum KeepAwakePlanner {
    /// 現在是否應持有 IOPMAssertion。
    ///
    /// - Parameters:
    ///   - startedAt: 進入該模式時的 uptime；`.duration` 以此起算。nil 視為未啟用。
    ///   - connectedDisplayUUIDs: 目前在線的顯示器 UUID。
    ///   - runningAppBundleIDs: 目前執行中的 App bundle ID。
    ///   - agentsWorking: 目前是否有 AI agent 在工作（見 `AgentActivityPlanner`）。
    ///   - systemBusy: 目前系統負載狀態機是否要求持有（見 `SystemLoadActivityPlanner`）。
    ///
    /// 環境參數都不給預設值：漏傳等於「條件永遠不成立」，
    /// 而長亮失效是使用者最不想默默發生的事。
    public static func shouldHoldAssertion(
        mode: KeepAwakeMode,
        startedAt: Double?,
        now: Double,
        connectedDisplayUUIDs: Set<String>,
        runningAppBundleIDs: Set<String>,
        agentsWorking: Bool,
        systemBusy: Bool
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
        case .whileAgentsWorking:
            guard startedAt != nil else { return false }
            return agentsWorking
        case .whileSystemBusy:
            guard startedAt != nil else { return false }
            return systemBusy
        }
    }

    /// 這個模式在持有期間各要擋哪一種待機。
    ///
    /// 所有模式都擋螢幕待機。Agent 模式固定加擋系統待機，
    /// 其餘模式的系統待機保護依「連系統待機一起擋」開關決定。
    public static func assertionPlan(
        mode: KeepAwakeMode,
        alsoPreventSystemSleep: Bool
    ) -> KeepAwakeAssertionPlan {
        switch mode {
        case .whileAgentsWorking:
            KeepAwakeAssertionPlan(preventsDisplaySleep: true, preventsSystemSleep: true)
        case .off, .duration, .indefinite, .whileDisplayConnected, .whileAppRunning, .whileSystemBusy:
            KeepAwakeAssertionPlan(
                preventsDisplaySleep: true,
                preventsSystemSleep: alsoPreventSystemSleep
            )
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
    /// 螢幕／App／Agent／負載綁定模式是本機設定，不跨機遙控
    /// （對方的螢幕組合、執行中的 App、agent 與負載我們管不著）。
    public static func encode(_ mode: KeepAwakeMode) -> Double {
        switch mode {
        case .off: 0
        case .indefinite: -1
        case let .duration(seconds): seconds
        case .whileDisplayConnected, .whileAppRunning, .whileAgentsWorking, .whileSystemBusy: -1
        }
    }

    public static func decode(_ value: Double) -> KeepAwakeMode {
        if value < 0 { return .indefinite }
        if value == 0 { return .off }
        return .duration(seconds: value)
    }
}
