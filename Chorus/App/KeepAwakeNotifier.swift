import ChorusCore
import Foundation
import OSLog
import UserNotifications

/// 長亮因電量／溫度底線暫停時的系統通知。
///
/// 與 `FocusNotifier` 分開：測試 bundle 碰到 `UNUserNotificationCenter`
/// 會 crash，所以 controller 只依賴這個 protocol，測試注入空實作。
@MainActor
protocol KeepAwakeNotifying: AnyObject {
    func notifyPowerFloorPaused(_ state: PowerFloorState)
}

@MainActor
final class KeepAwakeNotifier: KeepAwakeNotifying {
    private static let log = ChorusLog.display
    private var didRequestAuthorization = false

    func notifyPowerFloorPaused(_ state: PowerFloorState) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "螢幕長亮已暫停")
        switch state {
        case .ok:
            return
        case .lowBattery:
            content.body = String(localized: "電量低於底線，接上電源後會自動恢復")
        case .critical:
            content.body = String(localized: "Mac 過熱，降溫後會自動恢復")
        }
        requestAuthorizationIfNeeded()
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "keep-awake-power-floor-\(UUID().uuidString)",
            content: content,
            trigger: nil
        ))
    }

    private func requestAuthorizationIfNeeded() {
        guard !didRequestAuthorization else { return }
        didRequestAuthorization = true
        Task {
            do {
                _ = try await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert])
            } catch {
                Self.log.error("長亮暫停通知授權失敗：\(error.localizedDescription)")
            }
        }
    }
}
