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
}
