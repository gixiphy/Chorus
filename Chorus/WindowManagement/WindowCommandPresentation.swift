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
        case .nextDisplay: return String(localized: "下一個螢幕")
        case .previousDisplay: return String(localized: "上一個螢幕")
        case .maximize: return String(localized: "填滿")
        case .center: return String(localized: "置中")
        case .restore: return String(localized: "還原")
        case .selectZone: return String(localized: "鍵盤選區")
        case .arrangeLeftRight: return String(localized: "左右並排")
        case .arrangeMainLeft: return String(localized: "1 大 2 小（左大）")
        case .arrangeMainRight: return String(localized: "1 大 2 小（右大）")
        case .arrangeThreeColumns: return String(localized: "三欄並排")
        case .arrangeQuarters: return String(localized: "四分並排")
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
        case .selectZone: return "keyboard"
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
        case .displays: return String(localized: "螢幕")
        case .common: return String(localized: "常用")
        case .arrange: return String(localized: "填滿與排列")
        case .advanced: return String(localized: "超寬與進階")
        }
    }
}

extension ShortcutScheme {
    var title: String {
        switch self {
        case .chorusBasic: return String(localized: "Chorus 基本")
        case .magnet: return String(localized: "Magnet 習慣")
        case .none: return String(localized: "全部不綁定")
        }
    }
}

/// 版型縮圖：螢幕外框＋區塊，畫法比照 macOS 綠燈選單——目標視窗那格實心，
/// 其他視窗的格子淡一階。純裝飾，名稱由輔助說明負責。
struct WindowCommandGlyph: View {
    let command: WindowCommand
    var size = CGSize(width: 20, height: 13)

    var body: some View {
        let blocks = command.previewBlocks
        let inset = max(2, size.height * 0.16)
        let spacing = blocks.count > 1 ? max(0.75, size.height * 0.05) : 0
        Group {
            if blocks.isEmpty {
                Image(systemName: command.symbolName)
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
