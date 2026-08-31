import Foundation

/// 風格（genre）EQ preset 目錄（B6 缺口批）。
///
/// 給「隨手套一個」的入口——與 AutoEq（校正那**一支耳機**）是不同責任：
/// preset 是口味，校正是修正。兩打左右的清單對齊消費級等化器的慣例。
///
/// 曲線是**自行編寫**的慣例形狀（搖滾＝V 形、人聲＝中頻拱起……），
/// 數值取整齊的 0.5 dB 刻度；不取自任何 GPL 專案（授權紅線）。
/// 頻段沿用手動 10 段的 ISO 八度中心（31.5 Hz–16 kHz），Q=1。
/// 削波防護不在這裡做——套用後 `EQSettings.usesAutomaticPreamp`
/// 會以最大正增益自動算 negative preamp（與手動編輯同一條路）。
public struct EQGenrePreset: Sendable, Equatable, Identifiable {
    public let name: String
    /// 依手動 10 段頻率順序的增益（dB），固定 10 個值。
    public let gains: [Double]

    public var id: String { name }

    /// 展開成一組可直接套用的 EQSettings（開關開著、自動 preamp）。
    public func settings() -> EQSettings {
        var built = EQSettings.tenBandDefault()
        for (index, gain) in gains.enumerated() where index < built.bands.count {
            built.bands[index].gainDB = gain
        }
        built.sourceName = "Preset · \(name)"
        return built
    }

    /// 目錄順序：音樂風格在前（常用），工具型（增強／減弱）在後。
    public static let all: [EQGenrePreset] = [
        EQGenrePreset(name: "搖滾", gains: [5, 4, 3, 1, -1, -1, 0.5, 2.5, 3.5, 4.5]),
        EQGenrePreset(name: "流行", gains: [-1.5, -1, 0, 2, 4, 4, 2, 0, -1, -1.5]),
        EQGenrePreset(name: "爵士", gains: [4, 3, 1, 2, -2, -2, 0, 1, 3, 4]),
        EQGenrePreset(name: "古典", gains: [4.5, 3.5, 3, 2.5, -1.5, -1.5, 0, 2, 3, 4]),
        EQGenrePreset(name: "舞曲", gains: [3.5, 6, 5, 0, 2, 3.5, 5, 4.5, 3.5, 0]),
        EQGenrePreset(name: "電子", gains: [4, 3.5, 1, 0, -2, 2, 1, 1, 4, 4.5]),
        EQGenrePreset(name: "嘻哈", gains: [5, 4, 1.5, 3, -1, -1, 1.5, -0.5, 2, 3]),
        EQGenrePreset(name: "R&B", gains: [2.5, 6.5, 5.5, 1.5, -2, -1.5, 2.5, 2.5, 3, 3.5]),
        EQGenrePreset(name: "拉丁", gains: [4.5, 3, 0, 0, -1.5, -1.5, -1.5, 0, 3, 4.5]),
        EQGenrePreset(name: "原音", gains: [5, 5, 4, 1, 2, 1.5, 3.5, 4, 3.5, 2]),
        EQGenrePreset(name: "鋼琴", gains: [3, 2, 0, 2.5, 3, 1.5, 3.5, 4.5, 3, 3.5]),
        EQGenrePreset(name: "慵懶", gains: [-3, -1.5, -0.5, 1.5, 4, 2.5, 0, -1.5, 2, 1]),
        EQGenrePreset(name: "人聲增強", gains: [-2, -3, -3, 1.5, 4, 4, 3, 1.5, 0, -1.5]),
        EQGenrePreset(name: "口語", gains: [-3.5, -0.5, 0, 0.5, 3.5, 4.5, 4.5, 4, 2.5, 0]),
        EQGenrePreset(name: "低音增強", gains: [5.5, 4.5, 3.5, 2.5, 1, 0, 0, 0, 0, 0]),
        EQGenrePreset(name: "低音減弱", gains: [-5.5, -4.5, -3.5, -2.5, -1, 0, 0, 0, 0, 0]),
        EQGenrePreset(name: "高音增強", gains: [0, 0, 0, 0, 0, 1, 2.5, 3.5, 4.5, 5.5]),
        EQGenrePreset(name: "高音減弱", gains: [0, 0, 0, 0, 0, -1, -2.5, -3.5, -4.5, -5.5]),
        EQGenrePreset(name: "響度", gains: [6, 4, 0, 0, -2, 0, -1, -5, 5, 1]),
        EQGenrePreset(name: "小喇叭", gains: [5.5, 4.5, 3.5, 2.5, 1, 0, -1, -2.5, -3.5, -4.5]),
        EQGenrePreset(name: "平坦", gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]),
    ]
}
