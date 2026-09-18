import AppKit
import ChorusCore
import SwiftUI

struct WindowArrangementMenuSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if appState.settings.windowArrangementEnabled {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    if let name = appState.windowManager.targetAppName {
                        Text("目標：\(name)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if let message = appState.windowManager.statusMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    actionGrid
                    Divider()
                    ultrawideSection
                    Divider()
                    HStack {
                        Button("還原") { appState.windowManager.restoreLast() }
                        Button("鍵盤選區") { appState.windowManager.beginKeyboardZoneSelection() }
                        Button("上一螢幕") { appState.windowManager.moveToAdjacentDisplay(delta: -1) }
                        Button("下一螢幕") { appState.windowManager.moveToAdjacentDisplay(delta: 1) }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption)
                }
                .padding(.top, 4)
            } label: {
                Label("排列目前視窗", systemImage: "rectangle.split.3x1")
                    .font(.callout)
            }
            .onAppear { appState.windowManager.captureMenuTarget() }
        }
    }

    private var actionGrid: some View {
        let landscape = currentScreen()?.isLandscape ?? true
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                tile("左半", .leftHalf)
                tile("右半", .rightHalf)
                tile("上半", .topHalf)
                tile("下半", .bottomHalf)
            }
            HStack {
                tile("左上", .topLeft)
                tile("右上", .topRight)
                tile("左下", .bottomLeft)
                tile("右下", .bottomRight)
            }
            if landscape {
                HStack {
                    tile("左 1/3", .leftThird)
                    tile("中 1/3", .centerThird)
                    tile("右 1/3", .rightThird)
                }
                HStack {
                    tile("左 2/3", .leftTwoThirds)
                    tile("右 2/3", .rightTwoThirds)
                    tile("填滿", .maximize)
                    tile("置中", .centerPreserveSize)
                }
            } else {
                HStack {
                    tile("上 1/3", .topThird)
                    tile("中 1/3", .middleThird)
                    tile("下 1/3", .bottomThird)
                }
                HStack {
                    tile("上 2/3", .topTwoThirds)
                    tile("下 2/3", .bottomTwoThirds)
                    tile("填滿", .maximize)
                    tile("置中", .centerPreserveSize)
                }
            }
        }
    }

    @ViewBuilder
    private var ultrawideSection: some View {
        if let screen = currentScreen() {
            let templateID = appState.windowManager.templateID(for: screen)
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
            VStack(alignment: .leading, spacing: 4) {
                ForEach(template.zones) { zone in
                    Button(zoneLabel(zone)) {
                        appState.windowManager.applyUltrawide(zoneID: zone.id)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption)
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

    private func tile(_ title: String, _ action: LayoutAction) -> some View {
        Button(title) { appState.windowManager.apply(action) }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .font(.caption)
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
