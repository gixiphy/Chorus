/// 輸出裝置的偏好順位（B6-7）。
///
/// 純規則層。「哪個裝置該成為預設」是可以完整測試的邏輯，
/// 「什麼時候問這個問題」才需要碰 CoreAudio——把兩者分開，
/// 前者就不必為了被測到而去假裝一整個音訊系統。
///
/// FineTune 有同類行為（GPL，只讀行為描述、實作自寫，PLAN §8-1）。
public enum OutputPriority: Sendable {
    /// 現在該切到哪個裝置。`nil` ＝ 不要動。
    ///
    /// 三種 `nil` 的情況都很重要：
    /// - 沒設順位 → 功能等於關閉，絕不插手。
    /// - 順位裡沒有任何裝置在線 → 使用者現在用什麼就是什麼。
    /// - 最高順位的已經是預設 → 不要為了「確認」而重設一次
    ///   （切換預設裝置會讓正在播的音訊斷一下）。
    public static func preferred(
        order: [String],
        present: Set<String>,
        current: String?
    ) -> String? {
        guard !order.isEmpty else { return nil }
        guard let best = order.first(where: present.contains) else { return nil }
        return best == current ? nil : best
    }

    /// 剛接上、而且該還原音量的裝置（依順位排序）。
    ///
    /// 只還原**登記在順位裡**的裝置：那幾個正是使用者說過「我在意」的，
    /// 對其他裝置擅自改音量是意料之外的行為。
    public static func devicesToRestore(order: [String], arrived: Set<String>) -> [String] {
        order.filter(arrived.contains)
    }
}
