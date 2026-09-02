import ChorusCore
import Foundation
import OSLog
import UserNotifications

/// 限時場景結束時的系統通知（B7-3）。
///
/// 抽成 protocol 有兩個理由，測試只是其中之一：`UNUserNotificationCenter`
/// **在測試 bundle 裡取不到 bundle proxy 會直接 crash**，所以單元測試不能
/// 碰真的 center；另一個是 controller 的責任是「什麼時候該通知」，
/// 而「怎麼通知」是這裡的事。
@MainActor
protocol FocusNotifying: AnyObject {
    /// 要求通知授權。回傳是否取得——被拒時呼叫端要把開關彈回去，
    /// 不能留一個開著卻不會響的設定。
    func requestAuthorization() async -> Bool
    func notifyEnded(_ outcome: FocusOutcome)
}

@MainActor
final class FocusNotifier: FocusNotifying {
    private static let log = ChorusLog.focus

    /// 通知的內文。純函式，與 `UNUserNotificationCenter` 無關，
    /// 因此測試得到——文案是使用者唯一會讀到的東西。
    ///
    /// 兩種「沒回來」合成一個數字：使用者要知道的是「還有幾項停在場景
    /// 狀態」，不需要在通知裡分辨那是還原失敗還是本來就還不回來
    /// （選單那一行會分開講）。
    static func body(for outcome: FocusOutcome) -> String {
        let unrestored = outcome.failed.count + outcome.unrestorable.count
        guard unrestored > 0 else { return "已還原 \(outcome.restored) 項" }
        return "已還原 \(outcome.restored) 項，\(unrestored) 項未還原"
    }

    static func title(for outcome: FocusOutcome) -> String {
        outcome.reason == .relaunch
            ? "「\(outcome.sceneName)」已於啟動時還原"
            : "「\(outcome.sceneName)」結束"
    }

    /// **只要 `.alert`**：不要 sound、不要 badge。這是一則「事情已經做完了」
    /// 的告知，不是提醒——提醒音與紅點是蕃茄鐘的地盤，而定位裁決把那些排除了。
    func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert])
        } catch {
            Self.log.error("通知授權失敗：\(error.localizedDescription)")
            return false
        }
    }

    /// 立即送出（`trigger: nil`）。**不加動作按鈕**：能按的東西只有「再開一次」，
    /// 而那要重新選時長，在選單裡做比在通知裡做清楚。
    func notifyEnded(_ outcome: FocusOutcome) {
        let content = UNMutableNotificationContent()
        content.title = Self.title(for: outcome)
        content.body = Self.body(for: outcome)
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "focus-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }
}
