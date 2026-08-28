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
    /// 安裝結果或（不可寫時）使用者可自行貼進終端機的指令。
    @State private var cliInstallMessage: String?

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
                                case let .installed(path): "已安裝到 \(path)"
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
                    "只在回送介面（127.0.0.1）上接受連線，需要 Bearer token。"
                        + "跨機控制一律走已配對的加密同步通道，不經這個介面。"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
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
            ?? "未連接的裝置（\(uid.suffix(8))）"
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
                Text("開關與計時（30 分鐘／1 小時／無限期／接著某台螢幕時）在選單列。")
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
        case .displayServices: "Apple 原生"
        case .gammaOnly: "軟體調光"
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
            lines.append("IOAVService：" + (diag.hasService ? "已配對" : "無（DDC 不可用或已降級）"))
            if let transport = diag.transport {
                var line = "傳輸路徑：\(transport.upstream) → \(transport.downstream)"
                if transport.upstream.localizedCaseInsensitiveContains("DisplayPort"),
                   transport.downstream.localizedCaseInsensitiveContains("HDMI") {
                    line += "（DP→HDMI 轉換晶片：此路徑不透傳標準 DDC，請改接 DP／USB-C）"
                }
                lines.append(line)
            }
            lines.append(format("亮度 0x10", diag.brightness))
            lines.append(format("對比 0x12", diag.contrast))
            if let input = diag.inputSource {
                lines.append("輸入源 0x60：\(InputSource.describe(input.current))（raw \(input.current)）")
            } else {
                lines.append("輸入源 0x60：讀取失敗（螢幕不支援讀或通道不通）")
            }
            lines.append(format("音量 0x62", diag.volume))
            lines.append(format("靜音 0x8D", diag.mute))
            let failures = diag.failureCounts.filter { $0.value > 0 }
            if !failures.isEmpty {
                lines.append("寫入失敗計數：" + failures
                    .map { String(format: "0x%02X×%d", $0.key, $0.value) }
                    .sorted()
                    .joined(separator: "、"))
            }
            lines.append(contentsOf: troubleshootingHints(diag))
            result = lines.joined(separator: "\n")
            running = false
        }
    }

    private func format(_ name: String, _ value: (current: UInt16, max: UInt16)?) -> String {
        if let value { return "\(name)：\(value.current)／max \(value.max)" }
        return "\(name)：讀取失敗（螢幕不支援讀或通道不通）"
    }

    /// 硬體怪癖知識庫（B1/B2 實測累積）：依讀值與失敗計數給對症提示。
    private func troubleshootingHints(_ diag: DDCController.Diagnostics) -> [String] {
        var hints: [String] = []
        let anyReadable = [diag.brightness, diag.contrast, diag.inputSource, diag.volume, diag.mute]
            .contains { $0 != nil }
        if diag.hasService, !anyReadable {
            // 實測（Mac mini 內建 HDMI × Q34E2G5）：I2C 端點在、寫入被 ACK、
            // 讀取全滅＝轉換晶片本地假成功，螢幕實際收不到指令
            hints.append("▲ 讀取全滅但服務存在：寫入很可能是「假成功」（轉換晶片本地 ACK、不透傳）。改用 DP／USB-C 直連，或螢幕若有第二輸入埠可換埠。")
        }
        let volumeWriteFailures = diag.failureCounts[DDCController.VCP.volume] ?? 0
        if diag.brightness != nil, diag.volume == nil || volumeWriteFailures > 0 {
            hints.append("▲ 亮度可用但音量 0x62 不通：此螢幕不支援 DDC 音量。可在選單列該音訊裝置上按右鍵標記「不支援 DDC 音量」，滑桿會誠實停用。")
        }
        if diag.hasService, anyReadable {
            hints.append("ⓘ 若拖曳滑桿後畫面雪花／訊號異常：部分螢幕的 scaler 承受不了連續 I2C 寫入（已內建節流）。復發時開啟「強制軟體調光」並保留此診斷輸出回報。")
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if let detected, detected.selectable {
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
                statusText(engine: engine, detected: detected)
            }
            if let detected {
                Text(detected.url.path + (detected.version.map { "（\($0)）" } ?? ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                Text(engine.modelHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
        }
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

/// BV：虛擬輸出裝置（螢幕音量）。安裝／狀態／轉送目標／模式。
private struct AudioSettingsTab: View {
    @Environment(AppState.self) private var appState

    /// 權限狀態沒有 API 可查（DESIGN-M12 §1.2），文案要照實講「怎麼判的」。
    private var tapStateCaption: String {
        switch appState.tapEngine.state {
        case .off:
            "未啟用。"
        case .probing:
            "確認權限中——播放任何聲音即可完成檢查（權限被拒不會有錯誤訊息，只能靠聲音判讀）。"
        case .active:
            "就緒。選單列的「各 App 音量」可以逐一調整——沒調整過的 App 完全走原生路徑，不建立任何 tap。"
        case .denied:
            "偵測到系統音訊全為靜音——權限可能被拒。請到系統設定 → 隱私權與安全性 → 螢幕與系統音訊錄製 開啟 Chorus。"
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
            Section("輸出裝置等化") {
                if case .active = appState.tapEngine.state {
                    Text("每個輸出裝置一組。耳機校正（AutoEq）的主場景本來就不經虛擬裝置——直接對那支耳機開。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(appState.audioManager.devices) { device in
                        DisclosureGroup {
                            EQPanelView(device: device)
                        } label: {
                            HStack(spacing: 6) {
                                Text(device.name).font(.callout)
                                if device.isDefault {
                                    Text("預設")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: Capsule())
                                }
                                Spacer()
                                if appState.audioManager.eqSettings(for: device).isActive {
                                    Image(systemName: "waveform.path.ecg")
                                        .imageScale(.small)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    // 權限沒到手就整組隱藏功能本體，只留一句為什麼（DESIGN §6）
                    Text("需要先開啟上方的「App 音訊接管」——等化與 per-app 音量走同一套系統音訊擷取權限。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            get: { appState.virtualDriver.targetUID },
            set: { uid in
                guard let uid else { return }
                appState.virtualDriver.setTarget(uid: uid)
                appState.audioManager.updateVirtualMirrorMode()
            }
        )) {
            ForEach(proxyCandidates, id: \.uid) { device in
                Text(device.name).tag(Optional(device.uid))
            }
            if appState.virtualDriver.targetUID == nil {
                Text("（未設定）").tag(String?.none)
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
        Text("把音量鍵／Touch Bar 交給它：設為預設輸出。之後調整音量都會轉到上面選的實體輸出。")
            .font(.caption)
            .foregroundStyle(.secondary)
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
