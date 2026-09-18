import AppKit
import ApplicationServices
import ChorusCore
import SwiftUI

struct WindowArrangementSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var excludeDraft = ""

    var body: some View {
        Form {
            Section("啟用") {
                Toggle("啟用視窗排列", isOn: Binding(
                    get: { appState.settings.windowArrangementEnabled },
                    set: { enabled in
                        appState.settings.windowArrangementEnabled = enabled
                        appState.windowManager.updateActivation(promptIfNeeded: enabled)
                    }
                ))
                if appState.settings.windowArrangementEnabled {
                    if appState.windowManager.lastTrusted {
                        Label("輔助使用權限已授予", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        HStack {
                            Label("等待輔助使用權限…", systemImage: "exclamationmark.triangle")
                                .font(.caption)
                                .foregroundStyle(.orange)
                            Spacer()
                            Button("打開輔助使用設定") {
                                NSWorkspace.shared.open(
                                    URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                                )
                            }
                            .controlSize(.small)
                        }
                    }
                }
                Text("預設關閉。啟用後可用選單與 ⌃⌥ 快捷鍵排列前景視窗；拖曳吸附可另外開啟。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("拖曳吸附") {
                Toggle("啟用拖曳吸附", isOn: Binding(
                    get: { appState.settings.windowArrangementDragEnabled },
                    set: { enabled in
                        appState.settings.windowArrangementDragEnabled = enabled
                        appState.windowManager.updateDragActivation()
                    }
                ))
                .disabled(!appState.settings.windowArrangementEnabled)
                Text("直接拖到螢幕邊緣是基本型：左右半屏、四角、上緣填滿、下緣下半屏。按住 Shift 才切到特型：下緣分五段選 1/3、2/3，其餘位置依這台螢幕的超寬版型選區。放開 Shift 立即回到基本型；按 Esc 取消本趟。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("外觀") {
                Slider(
                    value: Binding(
                        get: { appState.settings.windowArrangementGap },
                        set: { appState.settings.windowArrangementGap = $0 }
                    ),
                    in: 0...24,
                    step: 1
                ) {
                    Text("間距")
                } minimumValueLabel: {
                    Text("0")
                } maximumValueLabel: {
                    Text("24")
                }
                Text("目前 \(Int(appState.settings.windowArrangementGap)) pt")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("每台螢幕的超寬佈局") {
                let topology = ScreenTopology.capture(generation: 0)
                if topology.screens.isEmpty {
                    Text("找不到螢幕")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(topology.screens, id: \.displayUUID) { screen in
                        VStack(alignment: .leading, spacing: 6) {
                            Picker(screenLabel(screen), selection: Binding(
                                get: { appState.windowManager.templateID(for: screen) },
                                set: { appState.windowManager.setTemplate($0, forDisplayUUID: screen.displayUUID) }
                            )) {
                                ForEach(LayoutTemplateID.allCases, id: \.self) { id in
                                    Text(templateTitle(id)).tag(id)
                                }
                            }
                            narrowZoneHint(for: screen)
                        }
                    }
                }
            }

            Section("排除 App") {
                ForEach(Array(appState.settings.windowArrangementExcludedBundleIDs).sorted(), id: \.self) { id in
                    HStack {
                        Text(id)
                            .font(.caption)
                            .textSelection(.enabled)
                        Spacer()
                        Button("移除") {
                            appState.settings.windowArrangementExcludedBundleIDs.remove(id)
                        }
                        .controlSize(.small)
                    }
                }
                HStack {
                    TextField("bundle id，例如 com.apple.Safari", text: $excludeDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("加入") {
                        let trimmed = excludeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        appState.settings.windowArrangementExcludedBundleIDs.insert(trimmed)
                        excludeDraft = ""
                    }
                    .controlSize(.small)
                }
                Text("排除的 App 不會成為排列目標。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("系統排列") {
                let conflicts = WindowArrangementConflicts.runningThirdPartyNames()
                if !conflicts.isEmpty {
                    Label("偵測到：\(conflicts.joined(separator: "、"))。可能與拖曳吸附重疊。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("若與 macOS 內建邊緣拖曳重疊，請到「桌面與 Dock」自行關閉系統選項。Chorus 不會代改系統偏好。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("打開桌面與 Dock 設定") {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension")!
                    )
                }
                .controlSize(.small)
            }

            // 逐項清單很長，放最後，不把螢幕佈局與排除 App 埋在下面
            WindowShortcutSettingsSection()
        }
        .formStyle(.grouped)
        .padding()
        .frame(minWidth: 640, minHeight: 560)
        .onAppear {
            appState.windowManager.updateActivation()
        }
    }

    @ViewBuilder
    private func narrowZoneHint(for screen: ScreenTopology.ScreenInfo) -> some View {
        let template = LayoutTemplateCatalog.template(id: appState.windowManager.templateID(for: screen))
        let zones = template.resolvedZones(
            visible: screen.visibleFrame,
            gap: appState.settings.windowArrangementGap
        )
        if zones.contains(where: { ZoneWidthHint.isNarrow($0.1.width) }) {
            Text("此分區較窄，部分 App 可能無法縮入")
                .font(.caption2)
                .foregroundStyle(.orange)
        }
    }

    private func screenLabel(_ screen: ScreenTopology.ScreenInfo) -> String {
        let ratio = screen.frame.width / max(screen.frame.height, 1)
        return String(format: "螢幕 %.0f×%.0f (%.2f:1)", screen.frame.width, screen.frame.height, ratio)
    }

    private func templateTitle(_ id: LayoutTemplateID) -> String {
        switch id {
        case .centerStage: return "中央主區"
        case .threeColumns: return "三欄"
        case .fourColumns: return "四欄"
        case .widePrimary: return "主副欄"
        case .widePrimaryMirrored: return "主副欄（鏡像）"
        case .primaryStack: return "主區＋雙側窗"
        case .primaryStackMirrored: return "主區＋雙側窗（鏡像）"
        case .centerReading: return "中央閱讀"
        }
    }
}
