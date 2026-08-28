/// 關閉單一顯示器的三層機制。能力不同的顯示器自動選用不同層，
/// UI 上一律只呈現「一顆電源鈕」。
public enum DisplayPowerLayer: String, Sendable, Codable, Hashable {
    /// DDC VCP 0xD6 寫入 DPMS off（0x04）。外接螢幕首選——背光真的斷電。
    /// 注意：**不用 0x05（hard off）**，部分螢幕硬關後不再回應 DDC，
    /// 只能按實體電源鍵救回。
    case ddc
    /// SkyLight soft-disconnect：把顯示器移出 display layout（等同拔線但免拔線）。
    /// 內建面板唯一的「真關閉」路徑；螢幕仍通電但背光滅、視窗會被 macOS 搬走。
    case softDisconnect
    /// gamma table 全黑。保底層：螢幕仍通電、只是畫面全黑。
    case gammaBlackout
}

/// 選層需要知道的顯示器能力。
public struct DisplayPowerCapability: Sendable, Equatable {
    /// 讀得到 VCP 0xD6（螢幕自報支援電源控制）。
    public var supportsDDCPower: Bool
    /// 本機的 SkyLight 私有 API 可用（spike 已驗證 macOS 26 可行）。
    public var supportsSoftDisconnect: Bool
    /// 這是目前唯一一台在線的顯示器。
    public var isOnlyActiveDisplay: Bool

    public init(
        supportsDDCPower: Bool,
        supportsSoftDisconnect: Bool,
        isOnlyActiveDisplay: Bool
    ) {
        self.supportsDDCPower = supportsDDCPower
        self.supportsSoftDisconnect = supportsSoftDisconnect
        self.isOnlyActiveDisplay = isOnlyActiveDisplay
    }
}

public enum DisplayPowerPlanner {
    /// 依能力挑一層。順序即偏好順序：真省電 > 真關閉 > 保底。
    ///
    /// **唯一一台顯示器時絕不 soft-disconnect**：把僅存的顯示器移出 layout
    /// 會讓使用者完全沒有畫面可操作，連復原手勢的視覺回饋都沒有。
    /// DDC 不受此限——那是外接螢幕的正常用法（Mac mini 單螢幕），
    /// 且螢幕實體電源鍵永遠救得回來。
    public static func layer(for capability: DisplayPowerCapability) -> DisplayPowerLayer {
        if capability.supportsDDCPower {
            return .ddc
        }
        if capability.supportsSoftDisconnect, !capability.isOnlyActiveDisplay {
            return .softDisconnect
        }
        return .gammaBlackout
    }
}

/// MCCS VCP 0xD6（Power Mode）的標準值。
public enum DisplayPowerValue {
    public static let on: UInt16 = 0x01
    public static let standby: UInt16 = 0x02
    public static let suspend: UInt16 = 0x03
    /// DPMS off——可由寫入 `on` 喚回。
    public static let off: UInt16 = 0x04
    /// Hard off。**Chorus 不使用**：部分螢幕硬關後 DDC 全滅。
    public static let hardOff: UInt16 = 0x05
}
