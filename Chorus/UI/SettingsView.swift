import ChorusCore
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
            Tab("音訊", systemImage: "speaker.wave.2") {
                AudioSettingsTab()
            }
            Tab("同步", systemImage: "arrow.triangle.2.circlepath") {
                SyncSettingsTab()
            }
            Tab("AI 引擎", systemImage: "brain") {
                AdvisorSettingsTab()
            }
            Tab("備份", systemImage: "icloud") {
                BackupSettingsTab()
            }
        }
        // 500 而非 460：六個英文分頁名（General…Analysis Engine…Backup）在 460 會把
        // 最後一頁擠進工具列的 » 溢出選單
        .frame(width: 500, height: 420)
        .environment(appState)
    }
}

private struct GeneralSettingsTab: View {
    @Environment(AppState.self) private var appState
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// 一條場景動作的人話描述。刻意貼近 CLI 的寫法，
    /// 使用者看得懂這一行，也就知道怎麼在終端重現它。
    private func describe(_ request: ControlRequest) -> String {
        let property = request.property?.rawValue ?? request.action?.rawValue ?? "?"
        let value = request.value.map { " \($0)" } ?? ""
        return "\(request.verb.rawValue) \(request.target.stringValue) \(property)\(value)"
    }

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
            LabeledContent("診斷紀錄") {
                HStack {
                    Text((DiagnosticLog.shared.fileURL.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button("在 Finder 顯示") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            DiagnosticLog.shared.existingFiles().isEmpty
                                ? [DiagnosticLog.shared.directory]
                                : [DiagnosticLog.shared.fileURL]
                        )
                    }
                    .controlSize(.small)
                }
            }
            Text("裝置插拔、預設輸出切換、場景套用與還原、App 音訊接管的每一步都記在這裡，2 MB 一輪、留三輪。聲音或畫面突然不對時，把這個檔連同發生時間一起回報。")
                .font(.caption)
                .foregroundStyle(.secondary)
            InterfaceLanguageSection()
            Section("場景") {
                if appState.sceneStore.scenes.isEmpty {
                    Text("尚無場景。在選單列按場景列的 ＋ 可把目前的亮度、音量與自動亮度狀態存成一組。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.sceneStore.scenes) { scene in
                        DisclosureGroup {
                            // 列出實際會做什麼——場景是會改硬體的東西，
                            // 使用者按下去前應該看得到內容，而不是只有一個名字
                            ForEach(Array(scene.requests.enumerated()), id: \.offset) { _, request in
                                Text(describe(request))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        } label: {
                            HStack {
                                Text(scene.name)
                                Spacer()
                                Text("\(scene.requests.count) 個動作")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Button("刪除", role: .destructive) {
                                    appState.sceneStore.delete(id: scene.id)
                                }
                                .controlSize(.small)
                            }
                        }
                    }
                }
                Text("選單列、`chorus scene <名稱>` 與 HTTP 觸發的是同一份。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            ?? String(localized: "未連接的裝置（\(uid.suffix(8))）")
    }
}

private struct DisplaySettingsTab: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section("螢幕長亮") {
                Toggle("連系統待機一起擋", isOn: Binding(
                    get: { appState.keepAwake.alsoPreventSystemSleep },
                    set: { appState.keepAwake.alsoPreventSystemSleep = $0 }
                ))
                Text(
                    appState.keepAwake.alsoPreventSystemSleep
                        ? "長亮期間螢幕與整台機器都不會待機（長時間下載／編譯用）。"
                        : "長亮期間只擋螢幕待機，機器仍會照系統設定進入睡眠。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text("開關與觸發條件（30 分鐘／1 小時／無限期／接著某台螢幕時／某個 App 執行時）在選單列。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                        Toggle("延伸調暗（硬體亮度到底後接續軟體調光）", isOn: Binding(
                            get: { display.subZeroDimming },
                            set: { appState.displayManager.setSubZeroDimming($0, for: display) }
                        ))
                        if display.subZeroDimming {
                            Text("滑桿下段 25% 改為軟體調光：外接螢幕的硬體最低亮度常常還是太亮，夜間可再往下壓。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if display.backend == .ddc, display.contrast != nil {
                        LabeledContent("對比") {
                            Slider(
                                value: Binding(
                                    get: { display.contrast ?? 0.5 },
                                    set: { appState.displayManager.setContrast($0, for: display) }
                                ),
                                in: 0...1
                            )
                            .frame(width: 130)
                            Text(display.contrast ?? 0.5, format: .percent.precision(.fractionLength(0)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                    if display.backend == .ddc {
                        LabeledContent("輸入源") {
                            Menu("切換…") {
                                ForEach(InputSource.allCases) { source in
                                    Button(source.label) {
                                        appState.displayManager.setInput(source.rawValue, for: display)
                                    }
                                }
                            }
                            .frame(width: 150)
                        }
                        Text("切到別的輸入後，這台 Mac 會失去此螢幕——由接在該輸入的機器（或螢幕實體按鈕）才能切回來。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if display.backend == .ddc || display.backend == .gammaOnly {
                        Toggle("停用 DDC 讀取（讀取造成閃爍時開啟；將直接信任 DDC 寫入）", isOn: Binding(
                            get: { appState.settings.disableDDCRead.contains(display.uuid) },
                            set: { enabled in
                                var set = appState.settings.disableDDCRead
                                if enabled { set.insert(display.uuid) } else { set.remove(display.uuid) }
                                appState.settings.disableDDCRead = set
                                // 讀取開關影響 DDC 分類（讀取驗證 vs 信任寫入）→ 重新分類
                                appState.displayManager.scheduleRefresh()
                            }
                        ))
                    }
                    if !display.isBuiltin {
                        DDCDiagnosticsRow(display: display)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func backendLabel(_ display: DisplayModel) -> String {
        switch display.backend {
        case .ddc: "DDC/CI"
        case .displayServices: String(localized: "Apple 原生")
        case .gammaOnly: String(localized: "軟體調光")
        }
    }
}

/// 外接螢幕的 DDC 診斷：服務配對、三個 VCP 讀值、寫入失敗計數。
/// 純讀取（不寫任何 VCP）；結果可選取複製，方便回報。
private struct DDCDiagnosticsRow: View {
    @Environment(AppState.self) private var appState
    let display: DisplayModel

    @State private var result: String?
    @State private var running = false

    var body: some View {
        LabeledContent("DDC 診斷") {
            Button(running ? "診斷中…" : "執行") { run() }
                .controlSize(.small)
                .disabled(running)
        }
        if let result {
            Text(result)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func run() {
        running = true
        result = nil
        let id = display.id
        Task {
            let diag = await appState.displayManager.ddc.diagnostics(id)
            var lines: [String] = []
            lines.append(diag.hasService ? String(localized: "IOAVService：已配對") : String(localized: "IOAVService：無（DDC 不可用或已降級）"))
            if let transport = diag.transport {
                var line = String(localized: "傳輸路徑：\(transport.upstream) → \(transport.downstream)")
                if transport.upstream.localizedCaseInsensitiveContains("DisplayPort"),
                   transport.downstream.localizedCaseInsensitiveContains("HDMI") {
                    line += String(localized: "（DP→HDMI 轉換晶片：此路徑不透傳標準 DDC，請改接 DP／USB-C）")
                }
                lines.append(line)
            }
            lines.append(format(String(localized: "亮度 0x10"), diag.brightness))
            lines.append(format(String(localized: "對比 0x12"), diag.contrast))
            if let input = diag.inputSource {
                lines.append(String(localized: "輸入源 0x60：\(InputSource.describe(input.current))（raw \(input.current)）"))
            } else {
                lines.append(String(localized: "輸入源 0x60：讀取失敗（螢幕不支援讀或通道不通）"))
            }
            lines.append(format(String(localized: "音量 0x62"), diag.volume))
            lines.append(format(String(localized: "靜音 0x8D"), diag.mute))
            let failures = diag.failureCounts.filter { $0.value > 0 }
            if !failures.isEmpty {
                lines.append(String(localized: "寫入失敗計數：") + failures
                    .map { String(format: "0x%02X×%d", $0.key, $0.value) }
                    .sorted()
                    .joined(separator: String(localized: "、")))
            }
            lines.append(contentsOf: troubleshootingHints(diag))
            result = lines.joined(separator: "\n")
            running = false
        }
    }

    private func format(_ name: String, _ value: (current: UInt16, max: UInt16)?) -> String {
        if let value { return String(localized: "\(name)：\(value.current)／max \(value.max)") }
        return String(localized: "\(name)：讀取失敗（螢幕不支援讀或通道不通）")
    }

    /// 硬體怪癖知識庫（B1/B2 實測累積）：依讀值與失敗計數給對症提示。
    private func troubleshootingHints(_ diag: DDCController.Diagnostics) -> [String] {
        var hints: [String] = []
        let anyReadable = [diag.brightness, diag.contrast, diag.inputSource, diag.volume, diag.mute]
            .contains { $0 != nil }
        if diag.hasService, !anyReadable {
            // 實測（Mac mini 內建 HDMI × Q34E2G5）：I2C 端點在、寫入被 ACK、
            // 讀取全滅＝轉換晶片本地假成功，螢幕實際收不到指令
            hints.append(String(localized: "▲ 讀取全滅但服務存在：寫入很可能是「假成功」（轉換晶片本地 ACK、不透傳）。改用 DP／USB-C 直連，或螢幕若有第二輸入埠可換埠。"))
        }
        let volumeWriteFailures = diag.failureCounts[DDCController.VCP.volume] ?? 0
        if diag.brightness != nil, diag.volume == nil || volumeWriteFailures > 0 {
            hints.append(String(localized: "▲ 亮度可用但音量 0x62 不通：此螢幕不支援 DDC 音量。可在選單列該音訊裝置上按右鍵標記「不支援 DDC 音量」，滑桿會誠實停用。"))
        }
        if diag.hasService, anyReadable {
            hints.append(String(localized: "ⓘ 若拖曳滑桿後畫面雪花／訊號異常：部分螢幕的 scaler 承受不了連續 I2C 寫入（已內建節流）。復發時開啟「強制軟體調光」並保留此診斷輸出回報。"))
        }
        return hints
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
                AmbientScheduleControls()
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

/// 時間排程兜底（只在無本機感器的機器顯示）：沒有 peer 回報時依日夜時段估環境光。
/// 這是估計不是量測，所以參數是「白天多亮、晚上多亮、幾點天亮、幾點天黑」，
/// 不談日照角也不要定位權限。
private struct AmbientScheduleControls: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Toggle("沒有其他裝置回報時，依時間排程估計環境光", isOn: Binding(
            get: { appState.settings.ambientScheduleEnabled },
            set: { appState.autoBrightness.setScheduleEnabled($0) }
        ))
        if appState.settings.ambientScheduleEnabled {
            LabeledContent("日間環境光") {
                luxSlider(\.dayLux, range: 50...2000)
            }
            LabeledContent("夜間環境光") {
                luxSlider(\.nightLux, range: 0...500)
            }
            LabeledContent("天亮時間") {
                minutePicker(\.dawnMinute)
            }
            LabeledContent("天黑時間") {
                minutePicker(\.duskMinute)
            }
            Text("天亮與天黑前後各半小時會平滑過渡。一有裝置回報真實環境光就改用那一份。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func luxSlider(_ keyPath: WritableKeyPath<AmbientSchedule, Double>, range: ClosedRange<Double>) -> some View {
        HStack {
            Slider(
                value: Binding(
                    get: { appState.settings.ambientSchedule[keyPath: keyPath] },
                    set: { value in
                        var schedule = appState.settings.ambientSchedule
                        schedule[keyPath: keyPath] = value
                        appState.autoBrightness.setSchedule(schedule)
                    }
                ),
                in: range
            )
            .frame(width: 160)
            Text("\(Int(appState.settings.ambientSchedule[keyPath: keyPath])) lx")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(width: 56, alignment: .trailing)
        }
    }

    /// 當日分鐘數 ↔ 時刻選擇器：日期部分固定用今天，只取時與分。
    private func minutePicker(_ keyPath: WritableKeyPath<AmbientSchedule, Int>) -> some View {
        DatePicker(
            "",
            selection: Binding(
                get: {
                    let minute = appState.settings.ambientSchedule[keyPath: keyPath]
                    return Calendar.current.date(
                        bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()
                    ) ?? Date()
                },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    var schedule = appState.settings.ambientSchedule
                    schedule[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                    appState.autoBrightness.setSchedule(schedule)
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
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

/// 兩位顧問（光環境、調音）共用的分析引擎：已知 CLI 目錄掃描結果、單選、
/// 自訂路徑與重新掃描。
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
                Text("本機的 AI CLI，供光環境顧問、調音顧問與介面翻譯共用。偵測到什麼列什麼，Chorus 不經手任何金鑰，計費在你自己的訂閱上。")
            }
            Section {
                Button("重新掃描") { appState.advisor.registry.rescanIncludingModels() }
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
        let enabled = appState.advisor.registry.isEnabled(engine.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let detected, detected.selectable, enabled {
                    // 勾選狀態看的是**實際會用到的**引擎，不是設定值本身：
                    // 選定的引擎被移除時 registry 會回落 claude，若這裡只比對
                    // 設定值就會一個都不打勾，看起來像沒有引擎可用。
                    Toggle(isOn: Binding(
                        get: { appState.advisor.registry.activeEngine?.id == engine.id },
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
                statusText(engine: engine, detected: detected, enabled: enabled)
                if detected != nil, !engine.pendingIntegration {
                    // 啟用開關（E0）：只控制是否允許 spawn。停用的引擎不會被
                    // 任何顧問使用、也不成為回落對象——分析計費在使用者的
                    // 訂閱上，不該有「默默換一家幫你花錢」的路徑。
                    Toggle("", isOn: Binding(
                        get: { appState.advisor.registry.isEnabled(engine.id) },
                        set: { appState.advisor.registry.setEnabled($0, engineID: engine.id) }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .help("停用後不會被任何顧問使用，也不會成為回落對象")
                }
            }
            if let detected {
                // 家目錄縮成 ~：路徑短一截，截圖／分享畫面時也不會露出使用者名稱
                Text((detected.url.path as NSString).abbreviatingWithTildeInPath
                    + (detected.version.map { "（\($0)）" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !engine.capabilities.contains(.vision) {
                    // 能力旗標（E0）：目前目錄六家都能看圖，這行是為未來的
                    // 純文字引擎留的——它可以服務調音顧問，但光環境顧問會跳過它。
                    Text("純文字引擎——光環境顧問（需要看圖）不會使用它")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                modelPicker(engine)
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

    /// 自訂模型欄位。留空＝不帶 `--model`，交給 CLI 自己決定。
    /// 用自由輸入而非下拉選單：只有 agy 有列舉指令且實測會卡住，
    /// 其餘 CLI 根本沒有列舉介面——一個欄位對五個引擎都成立。
    private func setModel(_ slug: String, for engine: KnownCLIEngine) {
        var ids = appState.settings.advisorModelIDs
        if slug.isEmpty { ids.removeValue(forKey: engine.id) } else { ids[engine.id] = slug }
        appState.settings.advisorModelIDs = ids
    }

    @ViewBuilder
    private func modelPicker(_ engine: KnownCLIEngine) -> some View {
        if engine.supportsModelSelection {
            // 一行到底、與上方路徑行同為 caption 級：直接把字串當 TextField 的
            // label 會被 Form 排進 leading 欄並折行，每個引擎的列高就不一樣了。
            HStack(spacing: 6) {
                Text("模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("", text: Binding(
                    get: { appState.settings.advisorModelIDs[engine.id] ?? "" },
                    set: { name in
                        var ids = appState.settings.advisorModelIDs
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        if trimmed.isEmpty {
                            ids.removeValue(forKey: engine.id)
                        } else {
                            ids[engine.id] = trimmed
                        }
                        appState.settings.advisorModelIDs = ids
                    }
                ), prompt: Text("預設"))
                .labelsHidden()
                .font(.caption)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 200)
                .help(engine.modelHint)
                // 列得到清單的引擎給下拉，但**欄位永遠可以自由輸入**——
                // 清單可能過期或列不全，不該因此擋住使用者想用的模型。
                let options = appState.advisor.registry.models[engine.id] ?? []
                if !options.isEmpty {
                    Menu {
                        Button("使用預設") { setModel("", for: engine) }
                        Divider()
                        ForEach(options, id: \.self) { slug in
                            Button(slug) { setModel(slug, for: engine) }
                        }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                            .imageScale(.small)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("從 \(engine.displayName) 回報的清單挑選")
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func statusText(engine: KnownCLIEngine, detected: AdviceEngineRegistry.DetectedEngine?, enabled: Bool) -> some View {
        if detected == nil {
            Text("未安裝").font(.caption).foregroundStyle(.secondary)
        } else if engine.pendingIntegration {
            Text("待接入").font(.caption).foregroundStyle(.orange)
                .help("此 CLI 的 headless 讀圖流程尚未打通，接入層完成後開放選用")
        } else if !enabled {
            Text("已停用").font(.caption).foregroundStyle(.secondary)
        } else {
            Text("已安裝").font(.caption).foregroundStyle(.green)
        }
    }

    private func badge(_ text: LocalizedStringKey) -> some View {
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

/// BV：虛擬輸出裝置（螢幕音量）。安裝／狀態／轉送目標／模式。
private struct AudioSettingsTab: View {
    @Environment(AppState.self) private var appState

    /// 權限狀態沒有 API 可查（DESIGN-M12 §1.2），文案要照實講「怎麼判的」。
    private var tapStateCaption: String {
        switch appState.tapEngine.state {
        case .off:
            String(localized: "未啟用。")
        case .probing:
            String(localized: "確認權限中——播放任何聲音即可完成檢查（權限被拒不會有錯誤訊息，只能靠聲音判讀）。")
        case .active:
            String(localized: "就緒。選單列的「各 App 音量」可以逐一調整——沒調整過的 App 完全走原生路徑，不建立任何 tap。")
        case .denied:
            String(localized: "偵測到系統音訊全為靜音——權限可能被拒。請到系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製 開啟 Chorus。")
        case let .failed(message):
            message
        }
    }

    private var tapStateIsError: Bool {
        switch appState.tapEngine.state {
        case .denied, .failed: true
        default: false
        }
    }
    @State private var busy = false
    @State private var errorMessage: String?
    /// 等化面板展開中的裝置。整列可點（不是只有 disclosure 小三角）——
    /// 點裝置名稱就把整個面板攤開。
    @State private var expandedEQDevices: Set<String> = []

    /// 已在順位裡的裝置，依順位排。已拔掉的也留著顯示——不然使用者
    /// 看不到自己設過什麼，也刪不掉。
    private var prioritisedDevices: [AudioDeviceModel] {
        appState.settings.outputPriority.compactMap { uid in
            appState.audioManager.devices.first { $0.uid == uid }
        }
    }

    private var unprioritisedDevices: [AudioDeviceModel] {
        appState.audioManager.devices.filter { appState.audioManager.priorityIndex(of: $0) == nil }
    }

    var body: some View {
        Form {
            Section("各 App 音量與等化") {
                Toggle("啟用 App 音訊接管", isOn: Binding(
                    get: { appState.settings.audioTapsEnabled },
                    set: { appState.tapEngine.setEnabled($0) }
                ))
                Text(tapStateCaption)
                    .font(.caption)
                    .foregroundStyle(tapStateIsError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                if case .denied = appState.tapEngine.state {
                    HStack {
                        Button("重新檢查") { appState.tapEngine.retryPermission() }
                            .controlSize(.small)
                        Button("開啟系統設定") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .controlSize(.small)
                    }
                }
                Text("開啟後系統會詢問「系統音訊錄製」權限。音訊只在本機處理，不會傳送到任何地方；未被調整的 App 完全不經過 Chorus。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("裝置優先順序") {
                Text("接上時自動成為預設輸出，並還原上次的音量。只在裝置插拔時作用——手動選的裝置不會被搶走。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if appState.settings.outputPriority.isEmpty {
                    Text("尚未設定順位（功能關閉）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(prioritisedDevices) { device in
                    HStack(spacing: 6) {
                        Text("\((appState.audioManager.priorityIndex(of: device) ?? 0) + 1).")
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(device.name).font(.callout)
                        Spacer()
                        Button { appState.audioManager.movePriority(device, up: true) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(appState.audioManager.priorityIndex(of: device) == 0)
                        Button { appState.audioManager.movePriority(device, up: false) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(appState.audioManager.priorityIndex(of: device)
                            == appState.settings.outputPriority.count - 1)
                        Button("移除") { appState.audioManager.removeFromPriority(device) }
                            .controlSize(.small)
                    }
                }
                if !unprioritisedDevices.isEmpty {
                    Menu("加入裝置…") {
                        ForEach(unprioritisedDevices) { device in
                            Button(device.name) { appState.audioManager.addToPriority(device) }
                        }
                    }
                    .controlSize(.small)
                }
            }
            Section("提示音") {
                HStack {
                    Text("提示音音量")
                    Slider(
                        value: Binding(
                            get: { appState.alertVolume.volume },
                            set: { appState.alertVolume.setVolume($0) }
                        ),
                        in: 0...1
                    )
                    Text(appState.alertVolume.volume, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
                Text("與輸出音量分開的系統設定——「會議」場景可以只關提示音、不動音樂。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("輸出裝置調整") {
                Text("每個輸出裝置一組：左右平衡與等化。耳機校正（AutoEq）的主場景本來就不經虛擬裝置——直接對那支耳機開。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ForEach(appState.audioManager.devices) { device in
                    let expanded = expandedEQDevices.contains(device.uid)
                    VStack(alignment: .leading, spacing: 10) {
                        Button {
                            if expanded {
                                expandedEQDevices.remove(device.uid)
                            } else {
                                expandedEQDevices.insert(device.uid)
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "chevron.right")
                                    .imageScale(.small)
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(expanded ? .degrees(90) : .zero)
                                Text(device.name).font(.callout)
                                if device.isDefault {
                                    Text("預設")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                }
                                Spacer()
                                if appState.audioManager.isExcluded(device) {
                                    Text("已排除")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                        .help(AudioDeviceManager.excludedReason)
                                }
                                if device.balance != 0 {
                                    Image(systemName: "slider.horizontal.below.rectangle")
                                        .imageScale(.small)
                                        .foregroundStyle(.secondary)
                                        .help("左右平衡不在置中")
                                }
                                if appState.audioManager.eqSettings(for: device).isActive {
                                    Image(systemName: "waveform.path.ecg")
                                        .imageScale(.small)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            // 整列都是點擊範圍——不是只有 disclosure 的小三角
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if expanded {
                            let excluded = appState.audioManager.isExcluded(device)
                            if excluded {
                                // 設定全部保留、只是不生效——與 per-app 排除同一套
                                // 「控制項停用＋說明為什麼」的處理
                                Text("\(AudioDeviceManager.excludedReason)。設定會保留，在選單列對這個裝置按右鍵可以取消排除。")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Group {
                                // 平衡不吃 taps 閘：原生平衡（vmbc／stereo pan）
                                // 直接寫 HAL，權限流程與它無關
                                DeviceBalanceRow(device: device)
                                if case .active = appState.tapEngine.state {
                                    EQPanelView(device: device)
                                    Divider()
                                    EffectChainView(target: .device(device))
                                    Divider()
                                    AudioAdviceSection(target: .device(uid: device.uid))
                                }
                            }
                            .disabled(excluded)
                            .opacity(excluded ? 0.5 : 1)
                            if appState.tapEngine.state != .active {
                                // 權限沒到手就隱藏功能本體，只留一句為什麼（DESIGN §6）
                                Text("等化需要先開啟上方的「App 音訊接管」——與 per-app 音量走同一套系統音訊擷取權限。")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            Section("螢幕音量（虛擬輸出裝置）") {
                explanation
                switch appState.virtualDriver.status {
                case .notInstalled:
                    notInstalledRows
                case .installedNotLoaded:
                    installedNotLoadedRows
                case .active:
                    activeRows
                }
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { appState.virtualDriver.refreshStatus() }
    }

    private var explanation: some View {
        Text("DP/HDMI 螢幕音訊沒有系統音量，macOS 會停用 Touch Bar／控制中心／音量鍵。安裝虛擬輸出裝置後，把它設為預設輸出：系統音量 UI 全部恢復，音訊轉送到螢幕；支援 DDC 的螢幕直接鏡射硬體音量（不損音質），其餘用數位衰減。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var notInstalledRows: some View {
        LabeledContent("狀態") {
            Text("未安裝").foregroundStyle(.secondary)
        }
        HStack {
            Button(busy ? "安裝中…" : "安裝驅動…") { install() }
                .disabled(busy || VirtualAudioDriverController.bundledDriverURL == nil)
            Text("需要管理員密碼一次；會重啟音訊服務（聲音短暫中斷）。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if VirtualAudioDriverController.bundledDriverURL == nil {
            Text("找不到 App 內嵌的驅動——這個 App 可能已損壞，請重新安裝 Chorus。")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var installedNotLoadedRows: some View {
        LabeledContent("狀態") {
            Text("已安裝，等待音訊服務載入").foregroundStyle(.orange)
        }
        HStack {
            Button("重新整理") { appState.virtualDriver.refreshStatus() }
            if appState.virtualDriver.updateAvailable {
                Button(busy ? "更新中…" : "重新安裝驅動…") { install() }
                    .disabled(busy)
            }
            Button("移除驅動…", role: .destructive) { uninstall() }
                .disabled(busy)
            Text("剛安裝完請稍候幾秒再重新整理；一直沒出現時重開機。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var activeRows: some View {
        LabeledContent("狀態") {
            Text("運作中").foregroundStyle(.green)
        }
        Picker("轉送到", selection: Binding(
            get: { appState.settings.virtualTargetUID },
            set: { uid in
                appState.settings.virtualTargetUID = uid
                appState.audioManager.updateVirtualTarget()
            }
        )) {
            Text("自動（跟著使用中的螢幕）").tag(String?.none)
            ForEach(proxyCandidates, id: \.uid) { device in
                Text(device.name).tag(Optional(device.uid))
            }
        }
        LabeledContent("目前送到") {
            if let name = currentTargetName {
                Text(name).foregroundStyle(.secondary)
            } else {
                Text("找不到轉送目標——聲音會沒有").foregroundStyle(.orange)
            }
        }
        LabeledContent("音量模式") {
            switch appState.virtualDriver.mirrorMode {
            case true?:
                Text("DDC 硬體鏡射（不損音質）").foregroundStyle(.green)
            case false?:
                Text("數位衰減（軟體音量）").foregroundStyle(.secondary)
            case nil:
                Text("讀取中…").foregroundStyle(.secondary)
            }
        }
        if appState.virtualDriver.updateAvailable {
            HStack {
                Button(busy ? "更新中…" : "更新驅動…") { install() }
                    .disabled(busy)
                Text("App 內附的驅動比已安裝的新；更新會重啟音訊服務。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        HStack {
            if let virtualModel, !virtualModel.isDefault {
                Button("設為預設輸出") {
                    appState.audioManager.setAsDefault(virtualModel)
                }
            }
            Button("移除驅動…", role: .destructive) { uninstall() }
                .disabled(busy)
        }
        Text("把音量鍵／Touch Bar 交給它：設為預設輸出。自動模式下轉送目標會跟著使用中的螢幕走，螢幕關掉或拔掉就退回內建輸出——不會靜靜沒有聲音。選單列會把它與轉送目標併成一列。")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// driver 現在實際轉送到哪台（自動模式下會隨螢幕變動）。
    private var currentTargetName: String? {
        guard let uid = appState.virtualDriver.targetUID else { return nil }
        return appState.audioManager.devices.first { $0.uid == uid }?.name
    }

    private var virtualModel: AudioDeviceModel? {
        appState.audioManager.devices.first { $0.uid == VirtualAudioDriverController.deviceUID }
    }

    /// 轉送候選：虛擬裝置以外的所有輸出（螢幕裝置排最前）。
    private var proxyCandidates: [AudioDeviceModel] {
        appState.audioManager.devices
            .filter { $0.uid != VirtualAudioDriverController.deviceUID }
            .sorted { lhs, rhs in
                if lhs.canSetVolume != rhs.canSetVolume { return !lhs.canSetVolume }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func install() {
        busy = true
        errorMessage = nil
        Task {
            do {
                try await appState.virtualDriver.install()
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }

    private func uninstall() {
        busy = true
        errorMessage = nil
        Task {
            do {
                try await appState.virtualDriver.uninstall()
            } catch {
                errorMessage = error.localizedDescription
            }
            busy = false
        }
    }
}

private struct SyncSettingsTab: View {
    @Environment(AppState.self) private var appState
    /// 安裝結果或（不可寫時）使用者可自行貼進終端機的指令。
    @State private var cliInstallMessage: String?

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
            Section("自動化介面") {
                Toggle("啟用 localhost 控制介面", isOn: Binding(
                    get: { appState.settings.automationServerEnabled },
                    set: { enabled in
                        appState.settings.automationServerEnabled = enabled
                        appState.automationServer.updateActivation()
                    }
                ))
                if appState.settings.automationServerEnabled {
                    LabeledContent("狀態") {
                        if let error = appState.automationServer.lastError {
                            Text("啟動失敗：\(error)").foregroundStyle(.red)
                        } else if appState.automationServer.isRunning {
                            Text("執行中 · http://127.0.0.1:\(String(appState.settings.automationServerPort))")
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Text("啟動中…").foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Token") {
                        HStack {
                            Text(appState.automationServer.currentToken())
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                            Button("重新產生") {
                                appState.automationServer.regenerateToken()
                            }
                            .controlSize(.small)
                        }
                    }
                }
                if appState.settings.automationServerEnabled {
                    LabeledContent("命令列工具") {
                        HStack {
                            Button("安裝 chorus 到 /usr/local/bin") {
                                cliInstallMessage = switch appState.automationServer.installCLISymlink() {
                                case let .installed(path): String(localized: "已安裝到 \(path)")
                                case let .needsManualCommand(command): command
                                }
                            }
                            .controlSize(.small)
                        }
                    }
                    if let message = cliInstallMessage {
                        Text(message)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                Text(
                    "只在回送介面（127.0.0.1）上接受連線，需要 Bearer token。跨機控制一律走已配對的加密同步通道，不經這個介面。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
}

// MARK: - 備份（B8）

/// 設定備份到 iCloud Drive。
///
/// 這一頁刻意**從頭到尾不用「同步」兩個字**：使用者看到那兩個字會預期
/// 「兩台全部一樣」，而這裡是「這台寫出去、要用再手動挑一份匯入」。
/// 講錯一次，之後每一個沒被搬過去的設定都會被當成壞掉。
private struct BackupSettingsTab: View {
    @Environment(AppState.self) private var appState
    /// 挑好要匯入哪一台，按下去才真的蓋。
    @State private var pendingImport: BackupFile?

    var body: some View {
        @Bindable var settings = appState.settings
        Form {
            if !appState.cloudBackup.isAvailable {
                Label("這台沒有啟用 iCloud Drive，備份功能停用。",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("""
                備份的是**這台**的設定：場景、等化器與效果鏈、排除清單、\
                各種偏好。寫進你的 iCloud Drive，**不會自動套到別台**——\
                要用得在下面挑一份匯入。
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Button("立即備份") {
                        appState.cloudBackup.backupNow()
                    }
                    Button("在 Finder 顯示") {
                        appState.cloudBackup.revealInFinder()
                    }
                    Spacer()
                }

                Toggle("自動備份（每分鐘檢查一次）", isOn: $settings.cloudBackupEnabled)
                    .onChange(of: settings.cloudBackupEnabled) { _, _ in
                        appState.cloudBackup.updateActivation()
                    }

                if let date = appState.cloudBackup.lastBackupDate {
                    LabeledContent("上次備份") {
                        Text(date, format: .dateTime.month().day().hour().minute())
                            .foregroundStyle(.secondary)
                    }
                }
                switch appState.cloudBackup.status {
                case .idle:
                    EmptyView()
                case let .ok(message):
                    Label(message, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                Text(appState.cloudBackup.displayPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .disabled(!appState.cloudBackup.isAvailable)

            Section("各台的設定") {
                if appState.cloudBackup.files.isEmpty {
                    Text("iCloud 上還沒有任何備份。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.cloudBackup.files) { file in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.deviceName + (file.isSelf ? "（這台）" : ""))
                                Text(file.savedAt, format: .dateTime.month().day().hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button(file.isSelf ? "還原" : "匯入") { pendingImport = file }
                                .controlSize(.small)
                        }
                    }
                }
                Text("""
                從**別台**匯入時會跳過綁在機器上的設定：顯示器與音訊裝置的\
                個別調整、防睡眠綁定、效果隔離名單，以及要各台自己開的權限\
                （App 音訊接管、自動化介面、自動備份）。從**這台**自己的\
                備份還原則是全套。
                """)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Section("不會備份的") {
                Text("""
                配對資訊與自動化介面的 token（存在鑰匙串，備份是明文 JSON）、\
                亮度與音量的當下值、進行中的限時場景。換機器後配對要重做一次。
                """)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .onAppear { appState.cloudBackup.refresh() }
        .confirmationDialog(
            pendingImport.map { String(localized: "要套用「\($0.deviceName)」的設定嗎？") } ?? "",
            isPresented: Binding(get: { pendingImport != nil },
                                 set: { if !$0 { pendingImport = nil } }),
            titleVisibility: .visible
        ) {
            Button("套用", role: .destructive) {
                if let file = pendingImport { appState.cloudBackup.importBackup(file) }
                pendingImport = nil
            }
            Button("取消", role: .cancel) { pendingImport = nil }
        } message: {
            Text("這會蓋掉目前的設定。匯入前會先把現況另存一份，檔名帶「-before-import」。")
        }
    }
}
