import AppKit
import ChorusCore
import SwiftUI

struct WindowArrangementMenuSection: View {
    @Environment(AppState.self) private var appState
    @State private var isExpanded: Bool

    init(startExpanded: Bool = false) {
        _isExpanded = State(initialValue: startExpanded)
    }

    /// 所有排列操作共用四欄格線，未滿一列時仍保留相同欄寬。
    private static let singleWindowCommands: [WindowCommand] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .leftThird, .centerThird, .rightThird, .center,
        .leftTwoThirds, .centerTwoThirds, .rightTwoThirds, .restore,
        .firstFourth, .secondFourth, .thirdFourth, .lastFourth,
        .leftThreeFourths, .rightThreeFourths,
    ]
    private static let arrangeRow: [WindowCommand] =
        [.maximize] + WindowCommand.commands(in: .arrange)
    private static let glyphSize = CGSize(width: 30, height: 21)

    private var manager: WindowManager { appState.windowManager }

    var body: some View {
        if appState.settings.windowArrangementEnabled {
            RowDisclosure(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if let name = manager.targetAppName {
                        Text("目標：\(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(manager.statusMessage ?? String(localized: "沒有可排列的視窗"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    let screens = ScreenTopology.capture(generation: 0).screens

                    sectionHeader("移動與調整大小")
                    commandGrid(Self.singleWindowCommands, screenCount: screens.count)

                    Divider()
                    sectionHeader("填滿與排列")
                    commandGrid(Self.arrangeRow, screenCount: screens.count)
                    Text("目前視窗放主要位置，這台螢幕上其餘視窗依最近使用的順序填入。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = manager.statusMessage, manager.targetAppName != nil {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    if let screen = currentScreen() {
                        Divider()
                        Text(screen.supportsZoneTemplates
                            ? WindowCommand.Group.advanced.title
                            : String(localized: "直立螢幕"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        advancedSection(screen)
                    }

                    let destinations = screens.filter { $0.displayUUID != manager.targetDisplayUUID }
                    if screens.count > 1, !destinations.isEmpty {
                        Divider()
                        ForEach(destinations, id: \.displayUUID) { screen in
                            Button {
                                manager.moveToDisplay(uuid: screen.displayUUID)
                            } label: {
                                Label("移到「\(screen.name)」", systemImage: "display")
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .font(.callout)
                            .disabled(manager.targetAppName == nil)
                        }
                    }

                    Divider()
                    managementRow
                }
                .padding(.top, 4)
            } label: {
                Label("排列目前視窗", systemImage: "rectangle.split.3x1")
                    .font(.callout)
            }
            .onAppear { manager.captureMenuTarget() }
        }
    }

    // MARK: - 格子

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func tileGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 4), spacing: 8) {
            content()
        }
    }

    private func commandGrid(_ commands: [WindowCommand], screenCount: Int) -> some View {
        tileGrid {
            ForEach(commands, id: \.self) { command in
                commandTile(command, screenCount: screenCount)
            }
        }
    }

    private func commandTile(_ command: WindowCommand, screenCount: Int) -> some View {
        let reason = disabledReason(for: command, screenCount: screenCount)
        let chord = appState.settings.windowArrangementShortcuts[command]?.displayString
        return iconTile(
            title: command.title, hint: chord ?? "", disabledReason: reason
        ) {
            manager.perform(command)
        } label: {
            WindowCommandGlyph(command: command, size: Self.glyphSize)
        }
    }

    private var targetDisabledReason: String? {
        manager.targetAppName == nil
            ? manager.statusMessage ?? String(localized: "沒有可排列的視窗")
            : nil
    }

    private func iconTile<Glyph: View>(
        title: String, hint: String = "", disabledReason: String?,
        action: @escaping () -> Void, @ViewBuilder label: () -> Glyph
    ) -> some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity)
                .frame(height: Self.glyphSize.height + 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // 前景色固定成 primary 之後，停用不會自己變淡，要手動補
        .foregroundStyle(.primary)
        .opacity(disabledReason == nil ? 1 : 0.3)
        .disabled(disabledReason != nil)
        .help(disabledReason ?? [title, hint].filter { !$0.isEmpty }.joined(separator: "　"))
        .accessibilityLabel(title)
        .accessibilityHint(disabledReason ?? hint)
    }

    /// 停用原因；`nil`＝可用。沒有目標（含缺權限、已忽略）時所有排列動作都停用。
    private func disabledReason(for command: WindowCommand, screenCount: Int) -> String? {
        guard manager.targetAppName != nil else {
            return manager.statusMessage ?? String(localized: "沒有可排列的視窗")
        }
        switch command {
        case .nextDisplay, .previousDisplay:
            return screenCount > 1 ? nil : String(localized: "只有一台螢幕，無法移到其他螢幕")
        case .restore:
            return manager.canRestoreTarget ? nil : String(localized: "這個視窗還沒有排列過，沒有可還原的位置")
        default:
            return nil
        }
    }

    // MARK: - 特型分區

    @ViewBuilder
    private func advancedSection(_ screen: ScreenTopology.ScreenInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !screen.isLandscape {
                tileGrid {
                    tile(String(localized: "上 1/3"), .topThird)
                    tile(String(localized: "中 1/3"), .middleThird)
                    tile(String(localized: "下 1/3"), .bottomThird)
                    tile(String(localized: "上 2/3"), .topTwoThirds)
                    tile(String(localized: "下 2/3"), .bottomTwoThirds)
                }
            }
            if screen.supportsZoneTemplates {
                ultrawideSection(screen)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - 管理

    private var managementRow: some View {
        HStack {
            SettingsLink {
                Text("視窗排列設定…")
            }
            Spacer()
            if let app = manager.menuApp {
                if app.isIgnored {
                    Button("恢復管理「\(app.name)」") { manager.unignoreMenuApp() }
                } else {
                    Button("忽略「\(app.name)」") { manager.ignoreMenuApp() }
                        .help("不再排列這個 App 的視窗；可在設定的「排除 App」移除")
                }
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.caption)
    }

    @ViewBuilder
    private func ultrawideSection(_ screen: ScreenTopology.ScreenInfo) -> some View {
        let templateID = manager.templateID(for: screen)
        let template = LayoutTemplateCatalog.template(id: templateID)
        let gap = appState.settings.windowArrangementGap
        let zones = template.resolvedZones(visible: screen.visibleFrame, gap: gap)
        Text("\(screen.name)：\(templateTitle(templateID))")
            .font(.caption2)
            .foregroundStyle(.secondary)
        if zones.contains(where: { ZoneWidthHint.isNarrow($0.1.width) }) {
            Text("此分區較窄，部分 App 可能無法縮入")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
        tileGrid {
            ForEach(Array(template.zones.enumerated()), id: \.element.id) { index, zone in
                iconTile(title: zoneLabel(zone), hint: zoneChord(index), disabledReason: targetDisabledReason) {
                    manager.applyUltrawide(zoneID: zone.id)
                } label: {
                    WindowLayoutGlyph(blocks: zones.map { candidate, rect in
                        (previewRect(rect, in: screen.visibleFrame), candidate.id == zone.id)
                    }, size: Self.glyphSize)
                }
            }
            iconTile(
                title: WindowCommand.selectZone.title,
                hint: String(localized: "方向鍵移動、Enter 套用、Esc 取消"),
                disabledReason: targetDisabledReason
            ) {
                manager.perform(.selectZone)
            } label: {
                WindowCommandGlyph(command: .selectZone, size: Self.glyphSize)
            }
        }
    }

    private func zoneChord(_ index: Int) -> String {
        WindowCommand.commands(in: .advanced).first { $0.zoneIndex == index }
            .flatMap { appState.settings.windowArrangementShortcuts[$0]?.displayString } ?? ""
    }

    private func currentScreen() -> ScreenTopology.ScreenInfo? {
        let topology = ScreenTopology.capture(generation: 0)
        let p = NSEvent.mouseLocation
        return topology.screens.first(where: {
            $0.frame.contains(Double(p.x), Double(p.y))
        }) ?? topology.screens.first
    }

    private func tile(_ title: String, _ action: LayoutAction) -> some View {
        let visible = LayoutRect(x: 0, y: 0, width: 600, height: 600)
        let rect = LayoutEngine().frame(for: action, visible: visible, gap: 0)
        return iconTile(title: title, disabledReason: targetDisabledReason) {
            manager.apply(action)
        } label: {
            WindowLayoutGlyph(blocks: [(previewRect(rect, in: visible), true)], size: Self.glyphSize)
        }
    }

    /// 排列引擎原點在左下；縮圖原點在左上。
    private func previewRect(_ rect: LayoutRect, in visible: LayoutRect) -> CGRect {
        CGRect(
            x: (rect.x - visible.x) / visible.width,
            y: (visible.maxY - rect.maxY) / visible.height,
            width: rect.width / visible.width,
            height: rect.height / visible.height
        )
    }

    private func templateTitle(_ id: LayoutTemplateID) -> String {
        switch id {
        case .centerStage: return "中央主區"
        case .threeColumns: return "三欄"
        case .fourColumns: return "四欄"
        case .widePrimary: return "2/3＋1/3"
        case .widePrimaryMirrored: return "1/3＋2/3"
        case .quarterSide: return "1/4＋3/4"
        case .quarterSideMirrored: return "3/4＋1/4"
        case .primaryStack, .primaryStackMirrored: return "主區＋雙側窗"
        case .centerReading: return "中央閱讀"
        }
    }

    private func zoneLabel(_ zone: LayoutZone) -> String {
        switch zone.id {
        case "left": return "左"
        case "center": return "中央主區"
        case "right": return "右"
        case "primary": return "主區"
        case "side": return "側欄"
        case "sideTop": return "上側窗"
        case "sideBottom": return "下側窗"
        case "reading": return "中央閱讀"
        case "col1": return "第 1 欄"
        case "col2": return "第 2 欄"
        case "col3": return "第 3 欄"
        case "col4": return "第 4 欄"
        default: return zone.id
        }
    }
}

/// 系統的 DisclosureGroup 只有前面的小箭頭能點；這裡整列（箭頭＋標題到右緣）都是展開鈕。
private struct RowDisclosure<Label: View, Content: View>: View {
    @Binding var isExpanded: Bool
    @ViewBuilder var content: () -> Content
    @ViewBuilder var label: () -> Label

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 10)
                    label()
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? Text("已展開") : Text("已收合"))
            if isExpanded {
                content()
            }
        }
    }
}
