import AppKit
import ChorusCore
import SwiftUI

struct WindowArrangementMenuSection: View {
    @Environment(AppState.self) private var appState
    @State private var isExpanded: Bool

    init(startExpanded: Bool = false) {
        _isExpanded = State(initialValue: startExpanded)
    }

    /// 比照 macOS 綠燈選單：分段標題＋純圖示格子，一列四格。
    private static let singleWindowRows: [[WindowCommand]] = [
        [.leftHalf, .rightHalf, .topHalf, .bottomHalf],
        [.topLeft, .topRight, .bottomLeft, .bottomRight],
        [.leftThird, .centerThird, .rightThird, .center],
        [.leftTwoThirds, .centerTwoThirds, .rightTwoThirds, .restore],
    ]
    private static let arrangeRow: [WindowCommand] =
        [.maximize] + WindowCommand.commands(in: .arrange)
    private static let glyphSize = CGSize(width: 30, height: 21)

    private var manager: WindowManager { appState.windowManager }

    var body: some View {
        if appState.settings.windowArrangementEnabled {
            DisclosureGroup(isExpanded: $isExpanded) {
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
                    ForEach(Self.singleWindowRows, id: \.self) { row in
                        tileRow(row, screenCount: screens.count)
                    }

                    Divider()
                    sectionHeader("填滿與排列")
                    tileRow(Self.arrangeRow, screenCount: screens.count)
                    Text("目前視窗放主要位置，這台螢幕上其餘視窗依最近使用的順序填入。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = manager.statusMessage, manager.targetAppName != nil {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }

                    // 橫向的一般比例螢幕沒有進階內容，整組不出現
                    if let screen = currentScreen(), screen.isUltrawide || !screen.isLandscape {
                        Divider()
                        DisclosureGroup {
                            advancedSection(screen)
                        } label: {
                            Text(screen.isUltrawide
                                ? WindowCommand.Group.advanced.title
                                : String(localized: "直立螢幕"))
                                .font(.caption)
                        }
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

    private func tileRow(_ commands: [WindowCommand], screenCount: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(commands, id: \.self) { command in
                commandTile(command, screenCount: screenCount)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func commandTile(_ command: WindowCommand, screenCount: Int) -> some View {
        let reason = disabledReason(for: command, screenCount: screenCount)
        let chord = appState.settings.windowArrangementShortcuts[command]?.displayString
        return Button {
            manager.perform(command)
        } label: {
            WindowCommandGlyph(command: command, size: Self.glyphSize)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // 前景色固定成 primary 之後，停用不會自己變淡，要手動補
        .foregroundStyle(.primary)
        .opacity(reason == nil ? 1 : 0.3)
        .disabled(reason != nil)
        .help(reason ?? [command.title, chord].compactMap { $0 }.joined(separator: "　"))
        .accessibilityLabel(command.title)
        .accessibilityHint(reason ?? chord ?? "")
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

    // MARK: - 超寬與進階

    @ViewBuilder
    private func advancedSection(_ screen: ScreenTopology.ScreenInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !screen.isLandscape {
                HStack {
                    tile("上 1/3", .topThird)
                    tile("中 1/3", .middleThird)
                    tile("下 1/3", .bottomThird)
                    tile("上 2/3", .topTwoThirds)
                    tile("下 2/3", .bottomTwoThirds)
                }
            }
            if screen.isUltrawide {
                ultrawideSection(screen)
                Button(WindowCommand.selectZone.title) { manager.perform(.selectZone) }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption)
                    .disabled(manager.targetAppName == nil)
                    .help("方向鍵移動、Enter 套用、Esc 取消")
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
        HStack {
            ForEach(template.zones) { zone in
                Button(zoneLabel(zone)) {
                    manager.applyUltrawide(zoneID: zone.id)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption)
                .disabled(manager.targetAppName == nil)
            }
        }
    }

    private func currentScreen() -> ScreenTopology.ScreenInfo? {
        let topology = ScreenTopology.capture(generation: 0)
        let p = NSEvent.mouseLocation
        return topology.screens.first(where: {
            $0.frame.contains(Double(p.x), Double(p.y))
        }) ?? topology.screens.first
    }

    private func tile(_ title: LocalizedStringKey, _ action: LayoutAction) -> some View {
        Button(title) { manager.apply(action) }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption)
            .disabled(manager.targetAppName == nil)
    }

    private func templateTitle(_ id: LayoutTemplateID) -> String {
        switch id {
        case .centerStage: return "中央主區"
        case .threeColumns: return "三欄"
        case .fourColumns: return "四欄"
        case .widePrimary, .widePrimaryMirrored: return "主副欄"
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
