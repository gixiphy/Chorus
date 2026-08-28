/// 可同步的控制項。
/// 帶 nil 識別碼的 case 是「語意層」控制（跨機同步用）：
/// `.brightness(nil)` = 所有已啟用同步的顯示器；`.volume(nil)` = 預設輸出裝置。
/// 帶明確識別碼的用於遙控特定裝置（display UUID / device UID 只對目標機器有意義）。
///
/// input／contrast 是遙控（command）專用：不做狀態同步（stateUpdate 不發也不收），
/// value 分別是 MCCS 輸入源代碼（原值）與 0–1 對比。舊版 peer 解不開新 case
/// 會逐則丟棄整包訊息，安全。
public enum ControlKey: Codable, Sendable, Hashable {
    case brightness(displayUUID: String?)
    case volume(deviceUID: String?)
    case mute(deviceUID: String?)
    /// 輸入源切換 VCP 0x60（`nil` 語意層無意義，僅為型別一致保留）。
    case input(displayUUID: String?)
    /// 對比 VCP 0x12。
    case contrast(displayUUID: String?)
    /// 螢幕電源（M9 三層：DDC 0xD6／soft-disconnect／gamma 黑屏，依能力自動選層）。
    /// value：1 = 開、0 = 關。`nil` = 本機所有顯示器。
    case displayPower(displayUUID: String?)
    /// 防睡眠。value 依 `KeepAwakePlanner.encode`：0 = 關、負值 = 無限期、正值 = 秒數。
    /// `nil` 為唯一有意義的形式（整機層級），識別碼僅為型別一致保留。
    case keepAwake(displayUUID: String?)
    /// 逐 App 音量（B6-6）。value 是 0–4 的增益。
    ///
    /// **command 專用，不進 LWW**：per-app 狀態是單機的——「把客廳那台的
    /// 音樂 App 關小聲」是遙控，不是要兩台機器收斂到同一個值。
    /// bundle id 不是可選的：沒有「語意層的某個 App」這種東西。
    case appVolume(bundleID: String)
    /// 逐 App 靜音。value：1 = 靜音、0 = 取消靜音。
    case appMute(bundleID: String)
}
