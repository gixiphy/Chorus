import Foundation

/// 選單列圖示要畫的東西。純資料——量化過的值，不含任何繪圖或 AppKit 型別，
/// 好讓「什麼時候該重畫」與「畫成什麼樣」兩件事都能單獨測。
public struct StatusIconState: Equatable, Sendable {
    /// 主要顯示器亮度 0–1。nil ＝ 沒有可控顯示器（環只畫軌道）。
    public var brightness: Double?
    /// 預設輸出裝置音量 0–1。nil ＝ 沒有可控輸出（聲波柱畫成最小）。
    public var volume: Double?
    /// 靜音（或音量被壓到 0 的 mute 狀態）——聲波柱改畫成一條橫線。
    public var isMuted: Bool
    /// 圖示右側的附加文字（倒數 `29:59`／無限期 `∞`）。nil ＝ 只畫圖示。
    ///
    /// 帶 `kind` 而不是只帶字串：畫出來兩者一樣，但**唸出來不一樣**。
    /// 無障礙標籤把限時場景的倒數唸成「螢幕長亮剩餘」，是說謊。
    public var badge: StatusBadge?

    public init(brightness: Double?, volume: Double?, isMuted: Bool, badge: StatusBadge?) {
        self.brightness = brightness
        self.volume = volume
        self.isMuted = isMuted
        self.badge = badge
    }
}

/// 徽章那一格在講誰的時間。
public enum StatusBadgeKind: Sendable, Equatable, Hashable {
    /// 防睡眠——可能是倒數，也可能是無限期的 `∞`。
    case keepAwake
    /// 限時場景（B7）的倒數。
    case focus
}

/// 選單列圖示右側那一格。
public struct StatusBadge: Sendable, Equatable, Hashable {
    public var text: String
    public var kind: StatusBadgeKind

    public init(text: String, kind: StatusBadgeKind) {
        self.text = text
        self.kind = kind
    }
}

public enum StatusIcon {
    /// 亮度／音量各自量化成幾階。拖曳滑桿時值會以每秒數十次的頻率變動，
    /// 但 18pt 的圖示上根本畫不出 1% 的差別——量化到 2.5% 一階，
    /// SwiftUI 才不會為了看不見的差異一直重畫。
    public static let steps = 40

    public static func quantize(_ value: Double?) -> Double? {
        guard let value else { return nil }
        let clamped = min(max(value, 0), 1)
        return (clamped * Double(steps)).rounded() / Double(steps)
    }

    /// 倒數文字。寬度由繪製端固定（monospaced digit ＋ 保留 5 字元），
    /// 這裡只負責內容。
    ///
    /// - 100 分鐘以上：`2h30`（`150:00` 太寬，而且沒人在讀秒）
    /// - 其餘：`M:SS`，含 `99:00`
    ///
    /// 選單提供 30m／1h，但自動化 API 可以送任意秒數，所以上面那條要成立。
    public static func countdownText(remainingSeconds: Double) -> String {
        let total = Int(max(0, remainingSeconds).rounded())
        if total >= 6000 {
            let hours = total / 3600
            let minutes = (total % 3600) / 60
            return String(format: "%dh%02d", hours, minutes)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// 防睡眠的狀態文字：計時中回倒數、其餘生效中的模式回 `∞`、沒生效回 nil。
    ///
    /// `∞` 這格是刻意的：無限期與「接著這台螢幕時」都沒有數字可報，
    /// 但選單列上得看得出來「我現在不會睡」——否則使用者只能點開選單確認。
    public static func keepAwakeBadge(remainingSeconds: Double?, isHolding: Bool) -> String? {
        badge(keepAwakeRemaining: remainingSeconds, keepAwakeHolding: isHolding, focusRemaining: nil)?.text
    }

    /// 選單列右側那格文字，把所有在跑的倒數收成一格（B7-1）。
    ///
    /// **同時有防睡眠與專注倒數時顯示較早到期的那個**：兩者都在回答
    /// 「什麼時候會有事發生」，先發生的那件更值得占用這一格。
    /// 圖示上不新增第四格資訊——選單列的空間是使用者的，不是我們的。
    ///
    /// `∞` 只在**沒有任何數字**時出現：有具體倒數卻讓一個沒有數字的符號
    /// 蓋住它，是拿資訊少的蓋掉資訊多的。
    public static func badge(
        keepAwakeRemaining: Double?,
        keepAwakeHolding: Bool,
        focusRemaining: Double?
    ) -> StatusBadge? {
        switch (keepAwakeRemaining, focusRemaining) {
        case let (keep?, focus?):
            // 同時到期時算防睡眠的：它是先存在的那個功能，換掉會讓已經
            // 習慣這格的人以為壞了
            return keep <= focus
                ? StatusBadge(text: countdownText(remainingSeconds: keep), kind: .keepAwake)
                : StatusBadge(text: countdownText(remainingSeconds: focus), kind: .focus)
        case let (keep?, nil):
            return StatusBadge(text: countdownText(remainingSeconds: keep), kind: .keepAwake)
        case let (nil, focus?):
            return StatusBadge(text: countdownText(remainingSeconds: focus), kind: .focus)
        case (nil, nil):
            return keepAwakeHolding ? StatusBadge(text: "∞", kind: .keepAwake) : nil
        }
    }
}
