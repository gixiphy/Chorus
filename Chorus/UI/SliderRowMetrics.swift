import SwiftUI

/// 選單列裡所有滑桿列共用的欄寬與尾端元件。
///
/// 螢幕亮度、輸出音量、提示音、各 App 音量、遙控 peer——五種列以前各自
/// 排版：有的左圖示沒有固定寬度、有的右邊沒有圖示欄、遙控列還多縮排
/// 13pt。結果是同一直欄裡的滑桿左右端點全都對不齊，看起來像五種不同
/// 層級的控制項。欄寬只在這裡定義一次。
enum SliderRow {
    /// 兩側圖示欄（左邊常是按鈕，右邊是「最大」那一端的圖示）。
    static let iconWidth: CGFloat = 16
    static let spacing: CGFloat = 8
    /// 百分比欄（等寬數字，三位數 + %）。
    static let valueWidth: CGFloat = 38

    /// 滑桿左端的圖示（不是按鈕時用這個，寬度與按鈕版一致）。
    static func leadingIcon(_ systemName: String) -> some View {
        icon(systemName)
    }

    /// 滑桿右端的「最大值」圖示。
    static func trailingIcon(_ systemName: String) -> some View {
        icon(systemName)
    }

    /// 百分比欄。
    static func value(_ value: Double) -> some View {
        Text(value, format: .percent.precision(.fractionLength(0)))
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(width: valueWidth, alignment: .trailing)
    }

    private static func icon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .imageScale(.small)
            .foregroundStyle(.secondary)
            .frame(width: iconWidth)
    }
}
