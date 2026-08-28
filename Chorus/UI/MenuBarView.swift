import ChorusCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    /// 暫時展開被隱藏的音訊裝置（右鍵可取消隱藏）；關閉選單不保留。
    @State private var showHiddenDevices = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chorus")
                    .font(.headline)
                Spacer()
                if let name = appState.instance.name {
                    Text(name)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
            }

            Divider()

            if appState.displayManager.displays.isEmpty {
                Text("找不到可控制的顯示器")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(appState.displayManager.displays) { display in
                        DisplaySliderRow(model: display, manager: appState.displayManager)
                    }
                }
            }

            AutoBrightnessRow()
            KeepAwakeRow()
            if appState.displayManager.hasPoweredOffDisplay {
                Button {
                    appState.displayManager.restoreAllDisplayPower()
                } label: {
                    Label("開啟所有已關閉的螢幕", systemImage: "power.circle.fill")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
            }

            Divider()

            Text("音訊輸出")
                .font(.caption)
                .foregroundStyle(.secondary)
            if appState.audioManager.devices.isEmpty {
                Text("找不到輸出裝置")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(listedAudioDevices) { device in
                        VolumeSliderRow(device: device, manager: appState.audioManager)
                            .opacity(appState.audioManager.isHidden(device) ? 0.55 : 1)
                    }
                }
                if hiddenCount > 0 {
                    Button {
                        showHiddenDevices.toggle()
                    } label: {
                        Label(
                            showHiddenDevices ? "收合隱藏的裝置" : "顯示 \(hiddenCount) 個隱藏裝置",
                            systemImage: showHiddenDevices ? "eye.slash" : "eye"
                        )
                        .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("展開後在裝置上按右鍵可取消隱藏")
                }
            }

            Divider()

            PeersSection()

            Divider()

            Button("結束 Chorus") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 300)
    }

    private var hiddenCount: Int {
        appState.audioManager.devices.count - appState.audioManager.visibleDevices.count
    }

    private var listedAudioDevices: [AudioDeviceModel] {
        showHiddenDevices ? appState.audioManager.devices : appState.audioManager.visibleDevices
    }
}

/// 自動亮度開關與環境光狀態列。
private struct AutoBrightnessRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle(isOn: Binding(
                get: { appState.settings.autoBrightnessEnabled },
                set: { appState.autoBrightness.setAutoEnabled($0) }
            )) {
                Label("自動亮度", systemImage: "sun.max.circle")
                    .font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Text(statusCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
    }

    private var statusCaption: String {
        let auto = appState.autoBrightness
        if auto.hasLocalSensor {
            if let lux = auto.currentLux {
                return "目前環境光 \(Int(lux.rounded())) lx"
            }
            return appState.settings.autoBrightnessEnabled ? "讀取環境光中…" : "使用本機光線感測器"
        }
        if let sourceID = auto.baselineSourceID, let lux = auto.baselineLux {
            let name = appState.pairedPeers.peers.first { $0.peerID == sourceID }?.deviceName ?? "其他裝置"
            return "跟隨 \(name) · \(Int(lux.rounded())) lx"
        }
        return "無光線感測器 — 等待其他裝置回報"
    }
}

/// 螢幕長亮（M9）。選單只放最常用的三檔＋螢幕綁定；
/// 「連系統待機一起擋」放設定頁，避免選單長出一排開關。
private struct KeepAwakeRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Label("螢幕長亮", systemImage: appState.keepAwake.isHolding ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .font(.callout)
                Spacer()
                Menu(menuLabel) {
                    Button("30 分鐘") { appState.keepAwake.activate(.duration(seconds: 1800)) }
                    Button("1 小時") { appState.keepAwake.activate(.duration(seconds: 3600)) }
                    Button("無限期") { appState.keepAwake.activate(.indefinite) }
                    if !appState.displayManager.displays.isEmpty {
                        Divider()
                        Menu("接著這台螢幕時") {
                            ForEach(appState.displayManager.displays) { display in
                                Button(display.name) {
                                    appState.settings.keepAwakeDisplayUUID = display.uuid
                                    appState.keepAwake.activate(.whileDisplayConnected(uuid: display.uuid))
                                }
                            }
                        }
                    }
                    if appState.keepAwake.mode != .off {
                        Divider()
                        Button("關閉") {
                            appState.settings.keepAwakeDisplayUUID = nil
                            appState.keepAwake.deactivate()
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            Text(statusCaption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
    }

    private var menuLabel: String {
        switch appState.keepAwake.mode {
        case .off: "關閉"
        case .indefinite: "無限期"
        case .duration: "計時中"
        case .whileDisplayConnected: "綁定螢幕"
        }
    }

    private var statusCaption: String {
        let keepAwake = appState.keepAwake
        switch keepAwake.mode {
        case .off:
            return "螢幕會照系統設定待機"
        case .indefinite:
            return keepAwake.alsoPreventSystemSleep ? "螢幕與系統都不會待機" : "螢幕不會待機"
        case .duration:
            guard let remaining = keepAwake.remainingSeconds else { return "計時中" }
            let minutes = Int(remaining) / 60
            let seconds = Int(remaining) % 60
            return String(format: "剩餘 %d:%02d", minutes, seconds)
        case let .whileDisplayConnected(uuid):
            let name = appState.displayManager.displays.first { $0.uuid == uuid }?.name
            guard let name else { return "綁定的螢幕未連接 — 暫停中" }
            return keepAwake.isHolding ? "接著「\(name)」時不待機" : "「\(name)」未連接 — 暫停中"
        }
    }
}

#Preview {
    MenuBarView()
        .environment(AppState())
}
