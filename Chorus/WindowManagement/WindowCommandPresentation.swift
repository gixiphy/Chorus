import ChorusCore
import SwiftUI

extension WindowCommand {
    var title: String {
        switch self {
        case .leftHalf: return String(localized: "左半屏")
        case .rightHalf: return String(localized: "右半屏")
        case .topHalf: return String(localized: "上半屏")
        case .bottomHalf: return String(localized: "下半屏")
        case .topLeft: return String(localized: "左上")
        case .topRight: return String(localized: "右上")
        case .bottomLeft: return String(localized: "左下")
        case .bottomRight: return String(localized: "右下")
        case .leftThird: return String(localized: "左三分之一")
        case .centerThird: return String(localized: "中央三分之一")
        case .rightThird: return String(localized: "右三分之一")
        case .leftTwoThirds: return String(localized: "左三分之二")
        case .centerTwoThirds: return String(localized: "中央三分之二")
        case .rightTwoThirds: return String(localized: "右三分之二")
        case .firstFourth: return String(localized: "第 1 個四分之一")
        case .secondFourth: return String(localized: "第 2 個四分之一")
        case .thirdFourth: return String(localized: "第 3 個四分之一")
        case .lastFourth: return String(localized: "第 4 個四分之一")
        case .leftThreeFourths: return String(localized: "左四分之三")
        case .rightThreeFourths: return String(localized: "右四分之三")
        case .nextDisplay: return String(localized: "下一個螢幕")
        case .previousDisplay: return String(localized: "上一個螢幕")
        case .maximize: return String(localized: "填滿")
        case .center: return String(localized: "置中")
        case .restore: return String(localized: "還原")
        case .restoreGroup: return String(localized: "還原整組")
        case .arrangeAuto: return String(localized: "自動排列")
        case .selectZone: return String(localized: "鍵盤選區")
        case .zone1: return String(localized: "放進第 1 區")
        case .zone2: return String(localized: "放進第 2 區")
        case .zone3: return String(localized: "放進第 3 區")
        case .zone4: return String(localized: "放進第 4 區")
        case .arrangeLeftRight: return String(localized: "左右並排")
        case .arrangeMainLeft: return String(localized: "1 大 2 小（左大）")
        case .arrangeMainRight: return String(localized: "1 大 2 小（右大）")
        case .arrangeThreeColumns: return String(localized: "三欄並排")
        case .arrangeQuarters: return String(localized: "四分並排")
        case .arrangeCenterStage: return String(localized: "中央主區並排")
        case .arrangeFourColumns: return String(localized: "四欄並排")
        case .arrangeWidePrimary: return String(localized: "2/3＋1/3 並排")
        case .arrangeWidePrimaryMirrored: return String(localized: "1/3＋2/3 並排")
        case .arrangeQuarterSide: return String(localized: "1/4＋3/4 並排")
        case .arrangeQuarterSideMirrored: return String(localized: "3/4＋1/4 並排")
        case .arrangePrimaryStack: return String(localized: "主區＋雙側窗並排")
        case .arrangePrimaryStackMirrored: return String(localized: "主區＋雙側窗並排（鏡像）")
        }
    }

    /// 選單格子用的短名；完整名稱放在輔助說明。
    var shortTitle: String {
        switch self {
        case .leftHalf: return String(localized: "左半")
        case .rightHalf: return String(localized: "右半")
        case .topHalf: return String(localized: "上半")
        case .bottomHalf: return String(localized: "下半")
        case .leftThird: return String(localized: "左 1/3")
        case .centerThird: return String(localized: "中 1/3")
        case .rightThird: return String(localized: "右 1/3")
        case .leftTwoThirds: return String(localized: "左 2/3")
        case .centerTwoThirds: return String(localized: "中 2/3")
        case .rightTwoThirds: return String(localized: "右 2/3")
        case .nextDisplay: return String(localized: "下一螢幕")
        case .previousDisplay: return String(localized: "上一螢幕")
        default: return title
        }
    }

    /// 版型縮圖：單位空間、原點在左上。非幾何指令沒有縮圖。
    var previewRect: CGRect? {
        switch self {
        case .leftHalf: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .rightHalf: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .topHalf: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottomHalf: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .topLeft: return CGRect(x: 0, y: 0, width: 0.5, height: 0.5)
        case .topRight: return CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
        case .bottomLeft: return CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: return CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .leftThird: return CGRect(x: 0, y: 0, width: 1.0 / 3, height: 1)
        case .centerThird: return CGRect(x: 1.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .rightThird: return CGRect(x: 2.0 / 3, y: 0, width: 1.0 / 3, height: 1)
        case .leftTwoThirds: return CGRect(x: 0, y: 0, width: 2.0 / 3, height: 1)
        case .centerTwoThirds: return CGRect(x: 1.0 / 6, y: 0, width: 2.0 / 3, height: 1)
        case .rightTwoThirds: return CGRect(x: 1.0 / 3, y: 0, width: 2.0 / 3, height: 1)
        case .firstFourth: return CGRect(x: 0, y: 0, width: 0.25, height: 1)
        case .secondFourth: return CGRect(x: 0.25, y: 0, width: 0.25, height: 1)
        case .thirdFourth: return CGRect(x: 0.5, y: 0, width: 0.25, height: 1)
        case .lastFourth: return CGRect(x: 0.75, y: 0, width: 0.25, height: 1)
        case .leftThreeFourths: return CGRect(x: 0, y: 0, width: 0.75, height: 1)
        case .rightThreeFourths: return CGRect(x: 0.25, y: 0, width: 0.75, height: 1)
        case .maximize: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .center: return CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        default: return nil
        }
    }

    /// 縮圖裡的區塊（單位空間、原點左上）；`primary`＝目標視窗會去的那格。
    var previewBlocks: [(rect: CGRect, primary: Bool)] {
        if let rect = previewRect { return [(rect, true)] }
        guard let arrangement else { return [] }
        return arrangement.slots.enumerated().map { index, slot in
            (CGRect(x: slot.x, y: 1 - slot.y - slot.height, width: slot.width, height: slot.height), index == 0)
        }
    }

    var symbolName: String {
        switch self {
        case .nextDisplay: return "arrow.right.to.line"
        case .previousDisplay: return "arrow.left.to.line"
        case .restore: return "arrow.uturn.backward"
        case .restoreGroup: return "arrow.uturn.backward.square"
        case .arrangeAuto: return "wand.and.stars"
        case .selectZone: return "keyboard"
        case .zone1: return "1.square"
        case .zone2: return "2.square"
        case .zone3: return "3.square"
        case .zone4: return "4.square"
        default: return "rectangle"
        }
    }
}

extension WindowCommand.Group {
    var title: String {
        switch self {
        case .halves: return String(localized: "半屏")
        case .quarters: return String(localized: "四角")
        case .thirds: return String(localized: "三分之一")
        case .twoThirds: return String(localized: "三分之二")
        case .fourths: return String(localized: "四分之一")
        case .threeFourths: return String(localized: "四分之三")
        case .displays: return String(localized: "螢幕")
        case .common: return String(localized: "常用")
        case .arrange: return String(localized: "填滿與排列")
        case .advanced: return String(localized: "特型分區")
        }
    }
}

/// 版型縮圖：螢幕外框＋區塊，畫法比照 macOS 綠燈選單——目標視窗那格實心，
/// 其他視窗的格子淡一階。純裝飾，名稱由輔助說明負責。
struct WindowCommandGlyph: View {
    let command: WindowCommand
    var size = CGSize(width: 20, height: 13)

    var body: some View {
        WindowLayoutGlyph(blocks: command.previewBlocks, symbolName: command.symbolName, size: size)
    }
}

/// 一般排列、直立與超寬分區共用相同外框、線寬與填色。
struct WindowLayoutGlyph: View {
    let blocks: [(rect: CGRect, primary: Bool)]
    var symbolName = "rectangle"
    var size = CGSize(width: 30, height: 21)

    var body: some View {
        let inset = max(2, size.height * 0.16)
        // 多窗格縮圖左右／上下要看得出縫，否則「左右分開」看起來像糊成一塊。
        let spacing = blocks.count > 1 ? max(2.5, size.height * 0.14) : 0
        Group {
            if blocks.isEmpty {
                Image(systemName: symbolName)
                    .font(.system(size: size.height * 0.75, weight: .medium))
            } else {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: size.height * 0.2)
                        .strokeBorder(lineWidth: max(1, size.height * 0.09))
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        let w = (size.width - inset * 2) * block.rect.width
                        let h = (size.height - inset * 2) * block.rect.height
                        RoundedRectangle(cornerRadius: size.height * 0.08)
                            .opacity(block.primary ? 1 : 0.45)
                            .frame(width: max(2, w - spacing), height: max(2, h - spacing))
                            .offset(
                                x: inset + (size.width - inset * 2) * block.rect.minX + spacing / 2,
                                y: inset + (size.height - inset * 2) * block.rect.minY + spacing / 2
                            )
                    }
                }
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

/// 選版型只更新每台螢幕的偏好；移動視窗仍由選單的分區按鈕負責。
struct WindowLayoutTemplatePicker: View {
    let visibleFrame: LayoutRect
    @Binding var selection: LayoutTemplateID

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
            ForEach(LayoutTemplateID.allCases, id: \.self) { id in
                let selected = selection == id
                Button {
                    selection = id
                } label: {
                    VStack(spacing: 8) {
                        WindowLayoutGlyph(blocks: previewBlocks(for: id), size: CGSize(width: 48, height: 32))
                        Text(title(for: id))
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(height: 28)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.2),
                                          lineWidth: selected ? 2 : 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .help(title(for: id))
                .accessibilityLabel(title(for: id))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func previewBlocks(for id: LayoutTemplateID) -> [(rect: CGRect, primary: Bool)] {
        // 使用這台螢幕的可見比例，中央閱讀的留白也會隨 21:9／32:9 正確改變。
        let zones = LayoutTemplateCatalog.template(id: id).resolvedZones(visible: visibleFrame, gap: 0)
        return zones.map { zone, rect in
            let primary = zone.isPrimary || zones.count == 1
                || id == .threeColumns || id == .fourColumns
            return (CGRect(
                x: (rect.x - visibleFrame.x) / visibleFrame.width,
                y: (visibleFrame.maxY - rect.maxY) / visibleFrame.height,
                width: rect.width / visibleFrame.width,
                height: rect.height / visibleFrame.height
            ), primary)
        }
    }

    private func title(for id: LayoutTemplateID) -> String {
        switch id {
        case .centerStage: return "中央主區"
        case .threeColumns: return "三欄"
        case .fourColumns: return "四欄"
        case .widePrimary: return "2/3＋1/3"
        case .widePrimaryMirrored: return "1/3＋2/3"
        case .quarterSide: return "1/4＋3/4"
        case .quarterSideMirrored: return "3/4＋1/4"
        case .primaryStack: return "主區＋雙側窗"
        case .primaryStackMirrored: return "主區＋雙側窗（鏡像）"
        case .centerReading: return "中央閱讀"
        }
    }
}

#Preview("版型縮圖") {
    VStack(alignment: .leading, spacing: 6) {
        ForEach(WindowCommand.allCases, id: \.self) { command in
            HStack {
                WindowCommandGlyph(command: command)
                Text(command.title)
            }
        }
    }
    .padding()
}
