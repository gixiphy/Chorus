import Foundation

/// 虛擬輸出裝置該把聲音轉送到哪裡的**規則**（純函式；硬體查詢在 app 端）。
///
/// 設計重點是最後一條 fallback：螢幕被關掉或拔掉時，寧可從內建喇叭出來，
/// 也不要靜靜地沒有聲音——使用者只會知道「Chorus 把音訊弄壞了」。
public enum VirtualOutputTarget {
    /// - Parameters:
    ///   - pinned: 使用者在設定裡指定的裝置（nil＝自動）。指定的裝置不在時
    ///     照樣往下退，回來時再接回去。
    ///   - present: 目前存在的輸出裝置 UID。
    ///   - activeScreen: 使用中那台螢幕的音訊裝置。
    ///   - liveScreens: 其他還亮著的螢幕的音訊裝置（依顯示順序）。
    ///   - anyScreens: 任何螢幕音訊裝置——螢幕沒被辨識成 DDC 顯示器時的補漏。
    ///   - builtin: 內建輸出（Mac 喇叭）。
    public static func preferred(
        pinned: String?,
        present: Set<String>,
        activeScreen: String?,
        liveScreens: [String],
        anyScreens: [String],
        builtin: String?
    ) -> String? {
        if let pinned, present.contains(pinned) { return pinned }
        if let activeScreen, present.contains(activeScreen) { return activeScreen }
        if let screen = liveScreens.first(where: { present.contains($0) }) { return screen }
        if let screen = anyScreens.first(where: { present.contains($0) }) { return screen }
        if let builtin, present.contains(builtin) { return builtin }
        return nil
    }
}
