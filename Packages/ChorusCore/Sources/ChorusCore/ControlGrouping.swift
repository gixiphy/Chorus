import Foundation

/// 亮度與音量操作介面的分組規則。
///
/// 兩邊用同一組分類，使用者才不用在兩個清單裡學兩套心智模型：
/// 「設備」是這台 Mac 本身、「螢幕」是掛在它上面的顯示器、「遠端」是別台 Mac。
///
/// 名字前面那個 `Device` 不是贅字：SwiftUI 有一個叫 `ControlGroup` 的容器 view，
/// 撞名會讓引入本套件的 SwiftUI 檔案整個型別查找失敗。
public enum DeviceControlGroup: String, Sendable, CaseIterable, Hashable {
    /// 本機內建：內建顯示器、內建喇叭與其他非螢幕輸出。
    case device
    /// 本機外接螢幕，以及螢幕自己的音訊端點。
    case screen
    /// 其他 Mac（依機器分組）。
    case remote

    /// 固定順序：設備 → 螢幕 → 遠端。空分類不保留標題（由 UI 過濾）。
    public static let displayOrder: [DeviceControlGroup] = [.device, .screen, .remote]
}

public enum ControlGrouping {
    /// 本機顯示器的分類。
    public static func group(isBuiltinDisplay: Bool) -> DeviceControlGroup {
        isBuiltinDisplay ? .device : .screen
    }

    /// 本機音訊輸出的分類。
    ///
    /// 判準是「它是不是某台螢幕的音訊端點」，不是傳輸介面本身——USB-C 螢幕的
    /// 音訊會走 USB，HDMI 擷取卡則不是螢幕。因此呼叫端要先做過名稱／DDC 比對，
    /// 這裡只接受結論。
    ///
    /// 虛擬輸出裝置（Chorus Screen Output）跟著它**目前轉送的目標**歸類：
    /// 使用者心裡的輸出目的地是那台螢幕，不是驅動程式。目標是螢幕就歸螢幕、
    /// 是內建喇叭就歸設備——這樣同一條音量控制不會同時出現在兩個分類裡。
    public static func group(isScreenAudioEndpoint: Bool) -> DeviceControlGroup {
        isScreenAudioEndpoint ? .screen : .device
    }

    /// 同名裝置的區別後綴：`nil` 表示不需要（名稱本身就唯一）。
    ///
    /// 只有真的撞名時才加尾碼——沒撞名卻掛一串序號只是雜訊。
    public static func disambiguationSuffixes(names: [String], discriminators: [String?]) -> [String?] {
        precondition(names.count == discriminators.count)
        var counts: [String: Int] = [:]
        for name in names { counts[name, default: 0] += 1 }
        return zip(names, discriminators).map { name, discriminator in
            counts[name, default: 0] > 1 ? discriminator : nil
        }
    }

    /// 短識別碼：同名裝置沒有序號可用時的退路。取前 6 碼已足夠區分，
    /// 完整 UUID 在一列名稱旁邊只會把名字擠掉。
    public static func shortIdentifier(_ identifier: String) -> String {
        String(identifier.prefix(6))
    }
}
