/// 可同步的控制項。
/// 帶 nil 識別碼的 case 是「語意層」控制（跨機同步用）：
/// `.brightness(nil)` = 所有已啟用同步的顯示器；`.volume(nil)` = 預設輸出裝置。
/// 帶明確識別碼的用於遙控特定裝置（display UUID / device UID 只對目標機器有意義）。
public enum ControlKey: Codable, Sendable, Hashable {
    case brightness(displayUUID: String?)
    case volume(deviceUID: String?)
    case mute(deviceUID: String?)
}
