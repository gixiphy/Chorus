import Foundation
import Observation

/// 提示音（alert／beep）音量的獨立控制（B6-7）。
///
/// macOS 的提示音音量與輸出音量是**兩個不同的東西**——「聲音」設定裡
/// 那條獨立的滑桿。它不是 CoreAudio 的屬性，而是 NSGlobalDomain 的
/// `com.apple.sound.beep.volume`（0–1）。沒有公開 API，但這個鍵是
/// 系統設定自己在讀寫的那一個，改完發一則通知就會生效。
///
/// 為什麼值得做：「會議模式」場景要的是**把提示音關掉而不動音樂**。
/// 用輸出音量做不到這件事——那會把兩者一起關掉。
@MainActor
@Observable
final class AlertVolumeController {
    private(set) var volume: Double = 0

    /// 系統設定改完之後發的通知。不發的話已經在跑的 App 會沿用舊值，
    /// 直到下次重新讀取——使用者會覺得「調了但沒用」。
    private static let changeNotification = "com.apple.sound.settingsChangedNotification"
    private static let key = "com.apple.sound.beep.volume"

    @ObservationIgnored private let defaults: UserDefaults

    /// `NSGlobalDomain` 而不是自己的 suite：這是系統的設定，不是我們的。
    ///
    /// 注意任何 `UserDefaults` 的搜尋清單都含全域網域，所以**讀**一定
    /// 讀得到系統現值；換 suite 只影響**寫**去哪裡（測試用）。
    init(defaults: UserDefaults = UserDefaults(suiteName: UserDefaults.globalDomain) ?? .standard) {
        self.defaults = defaults
        refresh()
    }

    func refresh() {
        volume = defaults.object(forKey: Self.key) as? Double ?? 1
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        defaults.set(clamped, forKey: Self.key)
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(Self.changeNotification), object: nil, deliverImmediately: true
        )
    }
}
