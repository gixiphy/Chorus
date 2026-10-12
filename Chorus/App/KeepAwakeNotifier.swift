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
    // §7.3 lid keep-awake（C08）
    func notifyLidGuardArmed(sources: [KeepAwakeSourceReport])
    func notifyLidGuardReleased(reason: LidBlockReason?, lidClosed: Bool)
    func notifyLidGuardHelperNeedsApproval()
    func notifyLeftoverRestored()
    func notifyLeftoverForeign()
    /// Fi A8：recovery-blocked leftover — 提示手動還原，不宣稱 external tool。
    func notifyLeftoverRecoveryNeeded()
    func notifyHelperForcedOff(reason: String)
}

extension KeepAwakeNotifying {
    func notifyLidGuardArmed(sources: [KeepAwakeSourceReport]) { _ = sources }
    func notifyLidGuardReleased(reason: LidBlockReason?, lidClosed: Bool) {
        _ = reason
        _ = lidClosed
    }
    func notifyLidGuardHelperNeedsApproval() {}
    func notifyLeftoverRestored() {}
    func notifyLeftoverForeign() {}
    func notifyLeftoverRecoveryNeeded() {}
    func notifyHelperForcedOff(reason: String) { _ = reason }
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
        deliver(content, prefix: "keep-awake-power-floor")
    }

    func notifyLidGuardArmed(sources: [KeepAwakeSourceReport]) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "闔上螢幕也不會睡")
        let names = sources.prefix(3).map(\.displayName).joined(separator: "、")
        let extra = sources.count > 3 ? String(localized: "等 \(sources.count - 3) 個") : ""
        let list = extra.isEmpty ? names : "\(names)、\(extra)"
        content.body = String(
            localized: "讓 Mac 保持清醒：\(list)。電量低於 30% 或過熱時會自動解除。"
        )
        deliver(content, prefix: "lid-guard-armed")
    }

    func notifyLidGuardReleased(reason: LidBlockReason?, lidClosed: Bool) {
        let content = UNMutableNotificationContent()
        switch reason {
        case let .maxDuration(limitSeconds):
            let hours = Int((limitSeconds / 3600).rounded())
            content.title = String(localized: "闔蓋已達 \(hours) 小時上限")
            content.body = String(localized: "Mac 即將睡眠；打開螢幕後會重新計算。")
        case let .lowBattery(percent, floor):
            content.title = String(localized: "闔蓋防睡已解除")
            if let percent {
                content.body = String(localized: "電量 \(percent)%，低於 \(floor)%，Mac 即將睡眠。")
            } else {
                content.body = String(localized: "電量低於 \(floor)%，Mac 即將睡眠。")
            }
        case .thermal:
            content.title = String(localized: "闔蓋防睡已解除")
            content.body = String(localized: "溫度過高，Mac 即將睡眠。")
        case .unknownPower, .lidUnknown, .noLid, .userPaused:
            content.title = String(localized: "闔蓋防睡已解除")
            content.body = String(localized: "安全條件不成立，Mac 即將睡眠。")
        case .none:
            guard lidClosed else { return }
            content.title = String(localized: "闔蓋防睡已解除")
            content.body = String(localized: "工作已結束，Mac 即將睡眠。")
        }
        deliver(content, prefix: "lid-guard-released")
    }

    func notifyLidGuardHelperNeedsApproval() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "需要允許 Chorus 輔助程序")
        content.body = String(localized: "到「登入項目與延伸功能」允許後，闔蓋防睡才會生效。")
        deliver(content, prefix: "lid-guard-helper-approval")
    }

    func notifyLeftoverRestored() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "已還原系統睡眠設定")
        content.body = String(localized: "上次 Chorus 未正常結束，闔蓋睡眠已恢復。")
        deliver(content, prefix: "lid-guard-leftover-restored")
    }

    func notifyLeftoverForeign() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "系統目前不會睡眠")
        content.body = String(localized: "SleepDisabled=1 不是 Chorus 設的，可能來自其他工具。")
        deliver(content, prefix: "lid-guard-leftover-foreign")
    }

    func notifyLeftoverRecoveryNeeded() {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "無法自動還原睡眠設定")
        content.body = String(
            localized: "輔助程序帳本異常，SleepDisabled 仍為 1。請手動執行 sudo pmset -a disablesleep 0。"
        )
        deliver(content, prefix: "lid-guard-leftover-recovery")
    }

    func notifyHelperForcedOff(reason: String) {
        let content = UNMutableNotificationContent()
        content.title = String(localized: "闔蓋防睡已被強制解除")
        content.body = String(localized: "原因：\(reason)")
        deliver(content, prefix: "lid-guard-forced-off")
    }

    private func deliver(_ content: UNMutableNotificationContent, prefix: String) {
        requestAuthorizationIfNeeded()
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "\(prefix)-\(UUID().uuidString)",
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
