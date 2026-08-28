import Foundation

/// 緊急復原手勢偵測：時間窗內連按 N 次 ⌘ 即觸發（學 Lunar，防止使用者
/// 把自己鎖在黑屏裡）。
///
/// 純狀態機、只吃時間戳——app 端負責接 flagsChanged 事件並判斷「⌘ 按下」，
/// 這裡不碰任何事件 API，因此可完整單元測試。
public struct EmergencyGestureDetector: Sendable, Equatable {
    public let requiredCount: Int
    public let window: TimeInterval
    private var stamps: [TimeInterval] = []

    public init(requiredCount: Int = 8, window: TimeInterval = 3) {
        self.requiredCount = max(requiredCount, 1)
        self.window = window
    }

    /// 記錄一次按壓。回傳 true 代表達成手勢（並自動重置，避免連續觸發）。
    public mutating func record(at time: TimeInterval) -> Bool {
        stamps.append(time)
        // 只留時間窗內的按壓；過期的不算數
        stamps.removeAll { time - $0 > window }
        guard stamps.count >= requiredCount else { return false }
        stamps.removeAll()
        return true
    }

    public mutating func reset() {
        stamps.removeAll()
    }

    /// 目前累積的有效按壓數（UI 可據此給提示；測試斷言用）。
    public var pendingCount: Int { stamps.count }
}
