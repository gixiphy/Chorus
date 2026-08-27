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
            Tab("分析引擎", systemImage: "brain") {
                AdvisorSettingsTab()
            }
        }
        .frame(width: 460, height: 420)
        .environment(appState)
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
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
                let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
                let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
                Text("\(short) (build \(build))")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Section("鍵盤媒體鍵") {
                Toggle("接管亮度／音量鍵", isOn: Binding(
                    get: { appState.settings.mediaKeyCaptureEnabled },
                    set: { enabled in
                        appState.settings.mediaKeyCaptureEnabled = enabled
                        appState.mediaKeys.updateActivation(promptIfNeeded: enabled)
                    }
                ))
                if appState.settings.mediaKeyCaptureEnabled {
                    if appState.mediaKeys.tapActive {
                        Label("已啟用", systemImage: "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else {
                        HStack {
                            Label("等待「輔助使用」權限…", systemImage: "exclamationmark.triangle")
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
                Text("只在 macOS 原生處理不了時接手：螢幕喇叭（HDMI/DP）的音量鍵、沒有內建螢幕機器（如 Mac mini）的亮度鍵。其餘按鍵行為維持原生。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !appState.settings.hiddenAudioDevices.isEmpty {
                Section("隱藏的音訊裝置") {
                    ForEach(Array(appState.settings.hiddenAudioDevices).sorted(), id: \.self) { uid in
                        HStack {
                            Text(deviceName(for: uid))
                            Spacer()
                            Button("取消隱藏") {
                                appState.settings.hiddenAudioDevices.remove(uid)
                            }
                            .controlSize(.small)
                        }
                    }
                    Text("在選單列的音訊裝置上按右鍵可以隱藏；成為預設輸出時仍會顯示。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    /// 隱藏裝置目前在線時顯示名稱，否則顯示 UID 尾段。
    private func deviceName(for uid: String) -> String {
        appState.audioManager.devices.first { $0.uid == uid }?.name
            ?? "未連接的裝置（\(uid.suffix(8))）"
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

/// 光環境顧問的分析引擎：已知 CLI 目錄掃描結果、單選、自訂路徑與重新掃描。
/// 零金鑰／零憑證經手——認證與計費都在使用者已登入的 CLI。
private struct AdvisorSettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                ForEach(KnownCLIEngine.catalog) { engine in
                    engineRow(engine)
                }
            } header: {
                Text("光環境顧問使用的本機 LLM CLI（偵測到什麼列什麼；不經手任何金鑰）")
            }
            Section {
                Button("重新掃描") { appState.advisor.registry.rescan() }
                Text("掃描順序：自訂路徑 → PATH → 常見安裝位置。找不到時可在上方填入執行檔完整路徑。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func engineRow(_ engine: KnownCLIEngine) -> some View {
        let detected = appState.advisor.registry.detected.first { $0.id == engine.id }
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let detected, detected.selectable {
                    Toggle(isOn: Binding(
                        get: { appState.settings.advisorEngineID == engine.id },
                        set: { on in if on { appState.settings.advisorEngineID = engine.id } }
                    )) {
                        Text(engine.displayName).fontWeight(.medium)
                    }
                    .toggleStyle(.checkbox)
                } else {
                    Text(engine.displayName)
                        .fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                if engine.experimental {
                    badge("實驗性")
                }
                Spacer()
                statusText(engine: engine, detected: detected)
            }
            if let detected {
                Text(detected.url.path + (detected.version.map { "（\($0)）" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                TextField(
                    "自訂 \(engine.executableName) 路徑（例：/opt/homebrew/bin/\(engine.executableName)）",
                    text: customPathBinding(engine.id)
                )
                .font(.caption)
                .onSubmit { appState.advisor.registry.rescan() }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func statusText(engine: KnownCLIEngine, detected: AdviceEngineRegistry.DetectedEngine?) -> some View {
        if detected == nil {
            Text("未安裝").font(.caption).foregroundStyle(.secondary)
        } else if engine.pendingIntegration {
            Text("待接入").font(.caption).foregroundStyle(.orange)
                .help("此 CLI 的 headless 讀圖流程尚未打通，接入層完成後開放選用")
        } else {
            Text("已安裝").font(.caption).foregroundStyle(.green)
        }
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    private func customPathBinding(_ engineID: String) -> Binding<String> {
        Binding(
            get: { appState.settings.advisorCustomPaths[engineID] ?? "" },
            set: { appState.settings.advisorCustomPaths[engineID] = $0 }
        )
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
