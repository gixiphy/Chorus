/// 自動化介面的四個動詞。CLI、localhost HTTP、MCP、TestHooks 與 Scenes
/// 全部共用同一組——新增入口不需要再翻譯一次語意。
///
/// 刻意**不做** BetterDisplay 的 `feed`（連續餵值）：DDC 的寫入節流在
/// `DDCController` 內，另開一個高頻入口只會繞過那道保護（雪花事故的由來）。
public enum ControlVerb: String, Codable, Sendable, CaseIterable, Hashable {
    /// 讀值。省略 property ＝ 回傳該目標的全部屬性——這是唯一的列舉入口。
    case get
    /// 寫值，絕對或相對（offset）。
    case set
    /// 布林翻轉。只對 boolean 屬性合法。
    case toggle
    /// 具名動作，不帶 property。
    case perform
}

/// `perform` 的具名動作。開放式參數放在請求的 `value`（例如場景名稱）。
public enum ControlAction: String, Codable, Sendable, CaseIterable, Hashable {
    /// 觸發具名場景；`value` 為場景名稱。
    case runScene
    /// 把所有被 Chorus 關掉的螢幕開回來（＝⌘×8 手勢的程式化版本）。
    case restoreAllPower
    /// 重新列舉顯示器與音訊裝置。
    case refresh
    /// 跑光環境顧問管線，回建議的 per-display offset。
    case suggestOffsets
    /// 提前結束進行中的限時場景並還原（B7）。走的是與倒數走完完全同一條路。
    case endScene
}
