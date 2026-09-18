import AppKit
import ChorusCore
import SwiftUI

struct WindowArrangementMenuSection: View {
    @Environment(AppState.self) private var appState

    private static let basicGroups: [WindowCommand.Group] = [
        .halves, .quarters, .thirds, .twoThirds, .displays, .common,
    ]

    private var manager: WindowManager { appState.windowManager }

    var body: some View {
        if appState.settings.windowArrangementEnabled {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    if let name = manager.targetAppName {
                        Text("目標：\(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text(manager.statusMessage ?? String(localized: "沒有可排列的視窗"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    let screenCount = ScreenTopology.capture(generation: 0).screens.count
                    ForEach(Self.basicGroups, id: \.self) { group in
                        groupRow(group, screenCount: screenCount)
                    }
                    disabledReasons(screenCount: screenCount)

                    Divider()
                    DisclosureGroup {
                        advancedSection
                    } label: {
                        Text(WindowCommand.Group.advanced.title)
                            .font(.caption)
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

    // MARK: - 基本動作

    private func groupRow(_ group: WindowCommand.Group, screenCount: Int) -> some View {
        HStack(alignment: .center, spacing: 4) {
            Text(group.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            ForEach(WindowCommand.commands(in: group), id: \.self) { command in
                commandTile(command, screenCount: screenCount)
            }
            Spacer(minLength: 0)
        }
    }

    private func commandTile(_ command: WindowCommand, screenCount: Int) -> some View {
        let reason = disabledReason(for: command, screenCount: screenCount)
        let chord = appState.settings.windowArrangementShortcuts[command]?.displayString
        return Button {
            manager.perform(command)
        } label: {
            VStack(spacing: 2) {
                WindowCommandGlyph(command: command)
                Text(command.shortTitle)
                    .font(.caption2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(minWidth: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
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

    /// 把個別停用的原因寫成看得到的字，不只靠灰掉與滑鼠停留提示。
    @ViewBuilder
    private func disabledReasons(screenCount: Int) -> some View {
        if manager.targetAppName != nil {
            let reasons = [WindowCommand.nextDisplay, .restore]
                .compactMap { disabledReason(for: $0, screenCount: screenCount) }
            ForEach(reasons, id: \.self) { reason in
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 超寬與進階

    @ViewBuilder
    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            ultrawideSection
            if currentScreen()?.isLandscape == false {
                HStack {
                    tile("上 1/3", .topThird)
                    tile("中 1/3", .middleThird)
                    tile("下 1/3", .bottomThird)
                    tile("上 2/3", .topTwoThirds)
                    tile("下 2/3", .bottomTwoThirds)
                }
            }
            Button(WindowCommand.selectZone.title) { manager.perform(.selectZone) }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .font(.caption)
                .disabled(manager.targetAppName == nil)
                .help("方向鍵移動、Enter 套用、Esc 取消")
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
    private var ultrawideSection: some View {
        if let screen = currentScreen() {
            let templateID = manager.templateID(for: screen)
            let template = LayoutTemplateCatalog.template(id: templateID)
            let gap = appState.settings.windowArrangementGap
            let zones = template.resolvedZones(visible: screen.visibleFrame, gap: gap)
            Text("超寬：\(templateTitle(templateID))")
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
