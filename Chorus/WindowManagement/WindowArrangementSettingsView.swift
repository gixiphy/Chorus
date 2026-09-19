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
                Text("直接拖到螢幕邊緣是基本型：左右半屏、四角、上緣填滿、下緣下半屏。按住 Shift 才切到特型：下緣分五段選 1/3、2/3；其餘位置依下方「特型拖曳佈局」選區。放開 Shift 立即回到基本型；按 Esc 取消本趟。")
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

            // 每台橫向螢幕各記一個版型（以 display UUID 存）；直立螢幕不切直欄，不列
            let templateScreens = ScreenTopology.capture(generation: 0).screens.filter(\.supportsZoneTemplates)
            if !templateScreens.isEmpty {
                Section("特型拖曳佈局") {
                    ForEach(templateScreens, id: \.displayUUID) { screen in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(screenLabel(screen, among: templateScreens))
                                .font(.callout.weight(.medium))
                            WindowLayoutTemplatePicker(visibleFrame: screen.visibleFrame, selection: Binding(
                                get: { appState.windowManager.templateID(for: screen) },
                                set: { appState.windowManager.setTemplate($0, forDisplayUUID: screen.displayUUID) }
                            ))
                            .accessibilityLabel(screenLabel(screen, among: templateScreens))
                            narrowZoneHint(for: screen)
                        }
                    }
                    Text("按住 Shift 拖曳視窗時，依視窗所在螢幕在這裡選的版型選區，每台螢幕各自記住；⌃⌥⇧1–4 則直接把目前視窗放進第 1–4 區（由左到右、由上到下）。切換版型不會搬動現有視窗。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        .padding(.vertical, 4)
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

    /// 用裝置名稱指認螢幕；同型號接兩台時才補解析度區分。
    private func screenLabel(_ screen: ScreenTopology.ScreenInfo, among screens: [ScreenTopology.ScreenInfo]) -> String {
        guard screens.filter({ $0.name == screen.name }).count > 1 else { return screen.name }
        return String(format: "%@（%.0f×%.0f）", screen.name, screen.frame.width, screen.frame.height)
    }

}
