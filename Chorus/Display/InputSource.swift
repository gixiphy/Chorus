import Foundation

/// VCP 0x60 的輸入源代碼（MCCS 2.2 標準值）。
/// 螢幕通常只實作自己有的埠；寫入不存在的代碼多半被忽略（無害）。
/// 部分廠牌的 USB-C 走自家代碼（如 LG 0xD0）——先收標準值，怪癖見診斷提示。
enum InputSource: UInt16, CaseIterable, Identifiable {
    case vga1 = 0x01
    case dvi1 = 0x03
    case dvi2 = 0x04
    case displayPort1 = 0x0F
    case displayPort2 = 0x10
    case hdmi1 = 0x11
    case hdmi2 = 0x12
    case usbC = 0x1B

    var id: UInt16 { rawValue }

    var label: String {
        switch self {
        case .vga1: "VGA"
        case .dvi1: "DVI 1"
        case .dvi2: "DVI 2"
        case .displayPort1: "DisplayPort 1"
        case .displayPort2: "DisplayPort 2"
        case .hdmi1: "HDMI 1"
        case .hdmi2: "HDMI 2"
        case .usbC: "USB-C"
        }
    }

    /// 讀值顯示：已知代碼給名稱，未知代碼給十六進位原值。
    static func describe(_ code: UInt16) -> String {
        InputSource(rawValue: code)?.label ?? String(format: "0x%02X", code)
    }
}
