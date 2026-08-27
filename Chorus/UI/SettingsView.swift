import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        TabView {
            Tab("一般", systemImage: "gearshape") {
                GeneralSettingsTab()
            }
            Tab("顯示器", systemImage: "display") {
                DisplaySettingsTab()
            }
            Tab("同步", systemImage: "arrow.triangle.2.circlepath") {
                SyncSettingsTab()
            }
        }
        .frame(width: 460, height: 420)
        .environment(appState)
    }
}

private struct GeneralSettingsTab: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Toggle("登入時啟動 Chorus", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            LabeledContent("版本") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct DisplaySettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            AmbientCurveSection()
            if appState.displayManager.displays.isEmpty {
                Text("找不到顯示器")
                    .foregroundStyle(.secondary)
            }
            ForEach(appState.displayManager.displays) { display in
                Section(display.name) {
                    LabeledContent("控制方式") {
                        Text(backendLabel(display))
                            .foregroundStyle(.secondary)
                    }
                    AmbientDisplayControls(displayUUID: display.uuid)
                    if display.backend != .gammaOnly {
                        Toggle("強制軟體調光", isOn: Binding(
                            get: { display.forceSoftwareDimming },
                            set: { appState.displayManager.setForceSoftwareDimming($0, for: display) }
                        ))
                    }
                    if display.backend == .ddc {
                        Toggle("停用 DDC 讀取（螢幕閃爍或讀取失敗時開啟）", isOn: Binding(
                            get: { appState.settings.disableDDCRead.contains(display.uuid) },
                            set: { enabled in
                                var set = appState.settings.disableDDCRead
                                if enabled { set.insert(display.uuid) } else { set.remove(display.uuid) }
                                appState.settings.disableDDCRead = set
                            }
                        ))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func backendLabel(_ display: DisplayModel) -> String {
        switch display.backend {
        case .ddc: "DDC/CI"
        case .displayServices: "Apple 原生"
        case .gammaOnly: "軟體調光"
        }
    }
}

/// 自動亮度總開關與曲線參數。
private struct AmbientCurveSection: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Section("自動亮度") {
            Toggle("依環境光自動調整亮度", isOn: Binding(
                get: { appState.settings.autoBrightnessEnabled },
                set: { appState.autoBrightness.setAutoEnabled($0) }
            ))
            if !appState.autoBrightness.hasLocalSensor {
                Text("這台 Mac 沒有光線感測器，將跟隨已配對裝置回報的環境光。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent("最暗亮度") {
                Slider(
                    value: Binding(
                        get: { appState.settings.ambientCurve.minBrightness },
                        set: { value in
                            appState.settings.ambientCurve.minBrightness = value
                            appState.autoBrightness.reapplyTargets()
                        }
                    ),
                    in: 0...0.5
                )
                .frame(width: 160)
                Text(appState.settings.ambientCurve.minBrightness, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 44, alignment: .trailing)
            }
            LabeledContent("全亮環境光") {
                Slider(
                    value: Binding(
                        get: { appState.settings.ambientCurve.maxLux },
                        set: { value in
                            appState.settings.ambientCurve.maxLux = value
                            appState.autoBrightness.reapplyTargets()
                        }
                    ),
                    in: 100...3000
                )
                .frame(width: 160)
                Text("\(Int(appState.settings.ambientCurve.maxLux)) lx")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 56, alignment: .trailing)
            }
        }
    }
}

/// 單一顯示器的自動亮度參與與差異值。
private struct AmbientDisplayControls: View {
    @Environment(AppState.self) private var appState
    let displayUUID: String

    var body: some View {
        Toggle("參與自動亮度", isOn: Binding(
            get: { !appState.settings.ambientExcludedDisplays.contains(displayUUID) },
            set: { included in
                var set = appState.settings.ambientExcludedDisplays
                if included { set.remove(displayUUID) } else { set.insert(displayUUID) }
                appState.settings.ambientExcludedDisplays = set
                appState.autoBrightness.reapplyTargets()
            }
        ))
        LabeledContent("亮度差異值") {
            Slider(
                value: Binding(
                    get: { appState.settings.ambientDisplayOffsets[displayUUID] ?? 0 },
                    set: { appState.autoBrightness.setDisplayOffset($0, for: displayUUID) }
                ),
                in: -0.5...0.5
            )
            .frame(width: 130)
            Text(offsetLabel)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 48, alignment: .trailing)
            Button("重設") {
                appState.autoBrightness.setDisplayOffset(0, for: displayUUID)
            }
            .controlSize(.small)
            .disabled((appState.settings.ambientDisplayOffsets[displayUUID] ?? 0) == 0)
        }
    }

    private var offsetLabel: String {
        let offset = appState.settings.ambientDisplayOffsets[displayUUID] ?? 0
        return String(format: "%+.0f%%", offset * 100)
    }
}

private struct SyncSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            Section("同步項目") {
                Toggle("同步亮度", isOn: $settings.syncBrightnessEnabled)
                Toggle("同步音量", isOn: $settings.syncVolumeEnabled)
            }
            Section("已配對的裝置") {
                if appState.pairedPeers.peers.isEmpty {
                    Text("尚未配對任何裝置")
                        .foregroundStyle(.secondary)
                }
                ForEach(appState.pairedPeers.peers) { peer in
                    HStack {
                        Text(peer.deviceName)
                        Spacer()
                        Text(peer.pairedAt, style: .date)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Button(role: .destructive) {
                            appState.pairedPeers.remove(peerID: peer.peerID)
                            appState.sessionManager.restartAdvertiser()
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}
