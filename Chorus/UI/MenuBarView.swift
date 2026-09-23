import ChorusCore
import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    /// 暫時展開被隱藏的音訊裝置（右鍵可取消隱藏）；關閉選單不保留。
    @State private var showHiddenDevices = false

    /// 捲動區的內容實際高度。用來讓選單「內容短就短、內容長才封頂」——
    /// 直接給 ScrollView 一個 maxHeight 會讓它永遠撐到最大，短內容時
    /// 是一大片空白。
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 12)
                .padding(.top, 12)

            Divider()
                .padding(.vertical, 8)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    displaySection
                    WindowArrangementMenuSection()
                    audioSection
                    AlertVolumeRow()
                    AppVolumeSection()
                    Divider()
                    PeersSection()
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    contentHeight = $0
                }
            }
            .frame(height: min(contentHeight, Self.maxScrollHeight))
            .scrollBounceBehavior(.basedOnSize)

            Divider()
                .padding(.vertical, 8)

            Button("結束 Chorus") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .frame(width: 300)
    }

    /// 捲動區的高度上限。選單列視窗**不會**自己長出捲軸——內容超過螢幕
    /// 就是直接被切掉、下面的東西按不到（`結束 Chorus`、配對區都在最下面）。
    /// 扣掉的是釘住的標頭、底部按鈕與兩條分隔線佔的空間。
    private static var maxScrollHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 700
        return max(240, visible - 140)
    }

    private var header: some View {
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
    }

    @ViewBuilder
    private var displaySection: some View {
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
    }

    @ViewBuilder
    private var audioSection: some View {
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
    }

    private var hiddenCount: Int {
        appState.audioManager.listableDevices.count - appState.audioManager.visibleDevices.count
    }

    private var listedAudioDevices: [AudioDeviceModel] {
        showHiddenDevices ? appState.audioManager.listableDevices : appState.audioManager.visibleDevices
    }
}

/// 提示音音量（B6-7）。與輸出音量分開的那條系統滑桿——
/// 「開會時把提示音關掉但音樂照放」用輸出音量做不到。
private struct AlertVolumeRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: SliderRow.spacing) {
            SliderRow.leadingIcon(appState.alertVolume.volume == 0 ? "bell.slash" : "bell")
                .help("提示音音量（與輸出音量分開）")
            Slider(
                value: Binding(
                    get: { appState.alertVolume.volume },
                    set: { appState.alertVolume.setVolumeCoalesced($0) }
                ),
                in: 0...1
            )
            SliderRow.trailingIcon("bell.fill")
            SliderRow.value(appState.alertVolume.volume)
        }
        // 背景讀：打開選單不等 AppleScript
        .onAppear { appState.alertVolume.refreshInBackground() }
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
                return String(localized: "目前環境光 \(Int(lux.rounded())) lx")
            }
            return appState.settings.autoBrightnessEnabled ? String(localized: "讀取環境光中…") : String(localized: "使用本機光線感測器")
        }
        if let sourceID = auto.baselineSourceID, let lux = auto.baselineLux {
            if auto.isFollowingSchedule {
                return String(localized: "依時間排程估計 · \(Int(lux.rounded())) lx")
            }
            let name = appState.pairedPeers.peers.first { $0.peerID == sourceID }?.deviceName ?? String(localized: "其他裝置")
            return String(localized: "跟隨 \(name) · \(Int(lux.rounded())) lx")
        }
        return String(localized: "無光線感測器 — 等待其他裝置回報")
    }
}

/// 螢幕長亮（M9）。選單只放最常用的三檔＋螢幕／App 綁定；
/// 「連系統待機一起擋」放設定頁，避免選單長出一排開關。
private struct KeepAwakeRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Label("螢幕長亮", systemImage: iconName)
                    .font(.callout)
                Spacer()
                Menu(menuLabel) {
                    Button("30 分鐘") { activate(.duration(seconds: 1800)) }
                    Button("1 小時") { activate(.duration(seconds: 3600)) }
                    Button("無限期") { activate(.indefinite) }
                    Divider()
                    if !appState.displayManager.displays.isEmpty {
                        Menu("接著這台螢幕時") {
                            ForEach(appState.displayManager.displays) { display in
                                Button(display.name) { activate(.whileDisplayConnected(uuid: display.uuid)) }
                            }
                        }
                    }
                    // 執行中的 App 每次重繪現查，不另外維護一份會過期的清單。
                    Menu("這個 App 執行時") {
                        ForEach(RunningApps.options()) { app in
                            Button(app.name) { activate(.whileAppRunning(bundleID: app.bundleID)) }
                        }
                    }
                    Button("有 agent 在工作時") { activate(.whileAgentsWorking) }
                    Button("高負載時") { activate(.whileSystemBusy) }
                    if appState.keepAwake.mode != .off {
                        Divider()
                        Button("關閉") { activate(.off) }
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

    /// Agent 模式擋的不是螢幕待機，杯子圖示會誤導；持有時改用機器人。
    private var iconName: String {
        let keepAwake = appState.keepAwake
        if keepAwake.mode == .whileAgentsWorking {
            return keepAwake.isHolding ? "cpu.fill" : "cpu"
        }
        return keepAwake.isHolding ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    /// 切模式時順手把「跨重啟記住的綁定」對齊：四個綁定互斥。
    private func activate(_ mode: KeepAwakeMode) {
        appState.keepAwake.selectMode(mode)
    }

    private var menuLabel: String {
        switch appState.keepAwake.mode {
        case .off: String(localized: "關閉")
        case .indefinite: String(localized: "無限期")
        case .duration: String(localized: "計時中")
        case .whileDisplayConnected: String(localized: "綁定螢幕")
        case .whileAppRunning: String(localized: "綁定 App")
        case .whileAgentsWorking: String(localized: "Agent")
        case .whileSystemBusy: String(localized: "高負載")
        }
    }

    private var statusCaption: String {
        let keepAwake = appState.keepAwake
        if keepAwake.activationFailed {
            return String(localized: "長亮尚未生效，正在重試")
        }
        switch keepAwake.mode {
        case .off:
            return String(localized: "螢幕會照系統設定待機")
        case .indefinite:
            return keepAwake.alsoPreventSystemSleep ? String(localized: "螢幕與系統都不會待機") : String(localized: "螢幕不會待機")
        case .duration:
            guard let remaining = keepAwake.remainingSeconds else { return String(localized: "計時中") }
            let minutes = Int(remaining) / 60
            let seconds = Int(remaining) % 60
            return String(format: String(localized: "剩餘 %d:%02d"), minutes, seconds)
        case let .whileDisplayConnected(uuid):
            let name = appState.displayManager.displays.first { $0.uuid == uuid }?.name
            guard let name else { return String(localized: "綁定的螢幕未連接 — 暫停中") }
            return keepAwake.isHolding ? String(localized: "接著「\(name)」時不待機") : String(localized: "「\(name)」未連接 — 暫停中")
        case let .whileAppRunning(bundleID):
            let name = RunningApps.displayName(for: bundleID)
            return keepAwake.isHolding ? String(localized: "「\(name)」執行中不待機") : String(localized: "「\(name)」未執行 — 暫停中")
        case .whileAgentsWorking:
            let engines = keepAwake.agentActivity.engines
            guard keepAwake.isHolding else { return String(localized: "沒有 agent 在工作 — 暫停中") }
            let count = String(keepAwake.agentActivity.working.count)
            let sources = engines.joined(separator: "、")
            return String(localized: "\(count) 個 \(sources) 在工作中 — 系統不待機")
        case .whileSystemBusy:
            return SystemLoadStatusFormatter.caption(
                evaluation: keepAwake.systemLoad.evaluation,
                sample: keepAwake.systemLoad.latestSample,
                isHolding: keepAwake.isHolding,
                alsoPreventSystemSleep: keepAwake.alsoPreventSystemSleep
            )
        }
    }
}

#Preview {
    MenuBarView()
        .environment(AppState())
}
