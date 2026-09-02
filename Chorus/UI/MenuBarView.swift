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
        FocusRow()
        ScenesRow()
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
        .onAppear { appState.alertVolume.refresh() }
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
            let name = appState.pairedPeers.peers.first { $0.peerID == sourceID }?.deviceName ?? String(localized: "其他裝置")
            return String(localized: "跟隨 \(name) · \(Int(lux.rounded())) lx")
        }
        return String(localized: "無光線感測器 — 等待其他裝置回報")
    }
}

/// 進行中的限時場景（B7-3）。
///
/// **沒有 session 時整列不佔位**——選單已經夠長，一個「目前沒有專注中」的
/// 空狀態不值得那幾十點高度。唯一的例外是上次沒正常結束、啟動時才還原的
/// 那一則：使用者不在場時發生的事要講一次，而且可以按掉。
private struct FocusRow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        if let session = appState.focus.session {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Label("專注中：「\(session.sceneName)」", systemImage: "timer")
                        .font(.callout)
                        // 長名字截斷、倒數與按鈕保持完整（實測「週一早上的深度
                        // 工作時段」會截成「週一早上的…」）；tooltip 補回全名
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(session.sceneName)
                    Spacer(minLength: 4)
                    Text(countdown)
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button("提前結束") {
                        appState.focus.end(reason: .manual)
                    }
                    .controlSize(.small)
                }
                Text(caption(session))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)
                    .help(session.snapshot.unrestorable.joined(separator: "、"))
            }
        } else if !appState.focus.pendingPeerRestores.isEmpty {
            // 對方離線時還原不了的跨機項目。**不做無限重試**——peer 一連上
            // 就自動補送，使用者也可以直接放棄；兩個出口都在這一行上
            HStack(spacing: 6) {
                Label(pendingSummary, systemImage: "exclamationmark.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("放棄") { appState.focus.abandonPendingRestores() }
                    .controlSize(.small)
            }
        } else if let outcome = appState.focus.lastOutcome, outcome.reason == .relaunch {
            HStack(spacing: 6) {
                Label("上次的「\(outcome.sceneName)」已於啟動時還原",
                      systemImage: "clock.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                Button {
                    appState.focus.dismissLastOutcome()
                } label: {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// 「2 項未還原（客廳、書房離線）」。名字列出來才知道要去開哪一台。
    private var pendingSummary: String {
        let pending = appState.focus.pendingPeerRestores
        let peers = Set(pending.compactMap(\.peer)).sorted()
        let names = peers.isEmpty ? String(localized: "對方") : peers.joined(separator: String(localized: "、"))
        return String(localized: "\(pending.count) 項未還原（\(names)離線）")
    }

    /// 與選單列圖示上那格是同一份文字——兩處對不上的話，使用者會以為
    /// 其中一個壞了。
    private var countdown: String {
        guard let remaining = appState.focus.remainingSeconds else { return "" }
        return StatusIcon.countdownText(remainingSeconds: remaining)
    }

    private func caption(_ session: FocusSession) -> String {
        var text = String(localized: "結束時還原 \(session.snapshot.restorableCount) 項")
        if !session.snapshot.unrestorable.isEmpty {
            // 數字之外還要能看到是哪幾項——滑上去有 tooltip
            text += String(localized: "；\(session.snapshot.unrestorable.count) 項不會自動還原")
        }
        return text
    }
}

/// 場景（B4-5）：具名的狀態組合，一鍵套用。與 CLI `chorus scene <名稱>`
/// 和 HTTP `perform runScene` 觸發的是同一份。
private struct ScenesRow: View {
    @Environment(AppState.self) private var appState
    @State private var naming = false
    @State private var draftName = ""
    /// 正在為哪個場景輸入自訂時長（B7-3）。contextMenu 裡放不了文字欄，
    /// 所以「自訂…」是把輸入列展開到場景列下方。
    @State private var customScene: ControlScene?
    @State private var draftDuration = ""
    /// 套用結果的短暫提示（哪幾項沒套上）。
    @State private var note: String?

    /// 子選單的預設檔位。25 分鐘擺第二個不是因為蕃茄鐘——那個定位裁決
    /// 已經排除了；純粹是「一段不被打擾的工作」最常見的長度。
    private static let presetMinutes = [15, 25, 45, 60]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Label("場景", systemImage: "rectangle.stack")
                    .font(.callout)
                Spacer()
                Button {
                    draftName = ""
                    naming.toggle()
                } label: {
                    Image(systemName: naming ? "xmark.circle" : "plus.circle")
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("以目前的亮度、音量與自動亮度狀態建立場景")
            }

            if naming {
                HStack(spacing: 6) {
                    TextField("場景名稱", text: $draftName)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit(save)
                    Button("儲存", action: save)
                        .controlSize(.small)
                        .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            if let scene = customScene {
                HStack(spacing: 6) {
                    TextField("時長（25m／1h／90s）", text: $draftDuration)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .onSubmit { start(scene, duration: draftDuration) }
                    Button("開始") { start(scene, duration: draftDuration) }
                        .controlSize(.small)
                        .disabled(draftDuration.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button {
                        customScene = nil
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if appState.sceneStore.scenes.isEmpty {
                Text("尚無場景——按 ＋ 把目前的亮度與音量存成一組")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                // 場景數量不定，用可換行的排列而不是固定欄數
                FlowRow(spacing: 6) {
                    ForEach(appState.sceneStore.scenes) { scene in
                        Button(scene.name) { run(scene) }
                            .controlSize(.small)
                            .contextMenu {
                                Menu("限時套用") {
                                    ForEach(Self.presetMinutes, id: \.self) { minutes in
                                        Button {
                                            start(scene, duration: "\(minutes)m")
                                        } label: {
                                            // 上次用過的打勾——多數人每次都用同一個長度
                                            if lastDurationMinutes == minutes {
                                                Label("\(minutes) 分鐘", systemImage: "checkmark")
                                            } else {
                                                Text("\(minutes) 分鐘")
                                            }
                                        }
                                    }
                                    Divider()
                                    Button("自訂…") {
                                        customScene = scene
                                        draftDuration = "\(lastDurationMinutes)m"
                                    }
                                    Divider()
                                    Toggle("結束時通知我", isOn: notifyBinding)
                                }
                                Divider()
                                Button("刪除「\(scene.name)」", role: .destructive) {
                                    appState.sceneStore.delete(id: scene.id)
                                }
                            }
                    }
                }
            }

            if let note {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func save() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        appState.sceneStore.save(appState.automation.captureCurrentScene(named: name))
        naming = false
        draftName = ""
        note = String(localized: "已建立「\(name)」")
    }

    private var lastDurationMinutes: Int {
        Int((appState.settings.focusLastDuration / 60).rounded())
    }

    /// 通知開關。**打開才要權限**（PLAN §8-6）；被拒時開關自動彈回去——
    /// 留一個開著卻不會響的設定，比沒有這個開關更糟。
    private var notifyBinding: Binding<Bool> {
        Binding(
            get: { appState.settings.focusNotifyOnEnd },
            set: { wanted in
                guard wanted else {
                    appState.settings.focusNotifyOnEnd = false
                    return
                }
                Task { @MainActor in
                    let granted = await appState.focusNotifier.requestAuthorization()
                    appState.settings.focusNotifyOnEnd = granted
                    if !granted {
                        note = String(localized: "系統設定裡未允許 Chorus 通知")
                    }
                }
            }
        )
    }

    /// 限時套用。走**動詞層**而不是直接呼叫 controller——時長的解析、錯誤
    /// 與 hint 全部與 CLI／HTTP 共用同一份，選單不會長出自己的規則。
    private func start(_ scene: ControlScene, duration: String) {
        customScene = nil
        note = String(localized: "正在套用「\(scene.name)」…")
        Task { @MainActor in
            // executeAsync：場景含跨機項目時要先把對方的現值問回來，
            // 否則還原時沒有原值可放。最多一秒
            let response = await appState.automation.executeAsync(ControlRequest(
                verb: .perform, target: .system, value: scene.name,
                action: .runScene, duration: duration
            ))
            if let error = response.error {
                note = error.message
                return
            }
            let failed = (response.results ?? []).filter { $0.property == "error" }.count
            note = failed == 0
                ? String(localized: "「\(scene.name)」限時套用中")
                : String(localized: "已套用「\(scene.name)」，\(failed) 項未生效（裝置已不在）")
        }
    }

    private func run(_ scene: ControlScene) {
        let response = appState.automation.execute(ControlRequest(
            verb: .perform, target: .system, value: scene.name, action: .runScene
        ))
        // 逐條套用，某幾條可能因螢幕已拔除而失敗——把數量講出來，
        // 不要讓使用者以為整組都生效了
        let failed = (response.results ?? []).filter { $0.property == "error" }.count
        note = failed == 0
            ? String(localized: "已套用「\(scene.name)」")
            : String(localized: "已套用「\(scene.name)」，\(failed) 項未生效（裝置已不在）")
    }
}

/// 依可用寬度換行的簡易排列（場景數量不定，固定欄數會空一大片或擠出去）。
private struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += lineHeight + spacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

/// 螢幕長亮（M9）。選單只放最常用的三檔＋螢幕／App 綁定；
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

    /// 切模式時順手把「跨重啟記住的綁定」對齊：兩個綁定互斥，
    /// 選了計時／無限期／關閉就都清掉——否則下次開機會冒出使用者
    /// 早就換掉的舊綁定。
    private func activate(_ mode: KeepAwakeMode) {
        if case let .whileDisplayConnected(uuid) = mode {
            appState.settings.keepAwakeDisplayUUID = uuid
        } else {
            appState.settings.keepAwakeDisplayUUID = nil
        }
        if case let .whileAppRunning(bundleID) = mode {
            appState.settings.keepAwakeAppBundleID = bundleID
        } else {
            appState.settings.keepAwakeAppBundleID = nil
        }
        appState.keepAwake.activate(mode)
    }

    private var menuLabel: String {
        switch appState.keepAwake.mode {
        case .off: String(localized: "關閉")
        case .indefinite: String(localized: "無限期")
        case .duration: String(localized: "計時中")
        case .whileDisplayConnected: String(localized: "綁定螢幕")
        case .whileAppRunning: String(localized: "綁定 App")
        }
    }

    private var statusCaption: String {
        let keepAwake = appState.keepAwake
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
        }
    }
}

#Preview {
    MenuBarView()
        .environment(AppState())
}
