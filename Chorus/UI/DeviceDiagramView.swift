import SwiftUI
import UniformTypeIdentifiers

/// 裝置配置視窗，分成三個區塊：
/// 配置圖（各裝置的亮度差異值控制）｜照片（把節點拖到實際位置）｜建議（光環境分析）。
/// 照片與建議可隱藏，配置圖恆在。
/// 差異值語意：疊加在環境基準亮度之上（本機顯示器改 ambientDisplayOffsets、
/// peer 節點送 setDeviceOffset 給對方）。
struct DeviceDiagramView: View {
    @Environment(AppState.self) private var appState
    @State private var showingImporter = false
    @State private var showingFirstUseConfirm = false
    @State private var showingScenarioName = false
    @State private var newScenarioName = ""
    @State private var showPhoto = true
    @State private var showAdvice = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                devicePane
                if showPhoto {
                    Divider()
                    photoPane
                }
                if showAdvice {
                    Divider()
                    advicePane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            advisorBar
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 400)
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $showPhoto) {
                    Label("照片", systemImage: "photo")
                }
                .help("顯示／隱藏照片區")
                Toggle(isOn: $showAdvice) {
                    Label("建議", systemImage: "lightbulb.max")
                }
                .help("顯示／隱藏建議區")
            }
        }
        // 注意：同一個 view 只能掛一個 fileImporter（掛兩個只有一個會生效），
        // 所以背景照與補充照共用同一次匯入：第一張當背景、其餘當補充視角。
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: true
        ) { result in
            if case let .success(urls) = result, let first = urls.first {
                let accessed = urls.filter { $0.startAccessingSecurityScopedResource() }
                appState.diagram.importBackground(from: first)
                appState.advisor.clearExtraPhotos()
                appState.advisor.importExtraPhotos(from: Array(urls.dropFirst()))
                for url in accessed { url.stopAccessingSecurityScopedResource() }
            }
        }
        // 分析完成或改看歷史時自動把建議區帶出來，結果才不會沒人看到。
        .onChange(of: appState.advisor.result?.id) { _, id in
            if id != nil { showAdvice = true }
        }
        .alert("分析光環境", isPresented: $showingFirstUseConfirm) {
            Button("繼續") {
                appState.settings.advisorConfirmed = true
                appState.advisor.analyze()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("照片將交由本機 \(engineName) CLI 分析（經你的訂閱送至其服務商）。分析只在你按下按鈕時發生。")
        }
        .alert("新增桌面情境", isPresented: $showingScenarioName) {
            TextField("名稱（例：家、公司）", text: $newScenarioName)
            Button("儲存") {
                appState.scenarios.createFromCurrent(named: newScenarioName)
                newScenarioName = ""
            }
            Button("取消", role: .cancel) { newScenarioName = "" }
        } message: {
            Text("記住目前的照片、節點位置與亮度設定；之後接上同一組螢幕會自動切換。")
        }
        .onAppear { appState.advisor.loadHistoryIfNeeded() }
    }

    private func paneTitle(_ title: LocalizedStringKey, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption)
            .fontWeight(.medium)
            .foregroundStyle(.secondary)
    }

    // MARK: - 配置圖區（裝置亮度控制）

    private var devicePane: some View {
        VStack(spacing: 0) {
            HStack {
                paneTitle("配置圖", systemImage: "slider.horizontal.3")
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            if nodes.isEmpty {
                Spacer()
                Text("沒有可顯示的裝置")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(nodes, id: \.key) { node in
                            DiagramNodeView(node: node)
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(minWidth: 180, idealWidth: 210, maxWidth: hasSidePanes ? 240 : .infinity)
    }

    private var hasSidePanes: Bool { showPhoto || showAdvice }

    // MARK: - 照片區（節點定位）

    private var photoPane: some View {
        VStack(spacing: 0) {
            HStack {
                paneTitle("照片", systemImage: "photo")
                Spacer()
                if appState.diagram.backgroundImageURL != nil {
                    Text("拖拉節點擺放實際位置")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
            photoCanvas
            Divider()
            photoBar
        }
        .frame(minWidth: 200, maxWidth: .infinity)
    }

    @ViewBuilder
    private var photoCanvas: some View {
        if appState.diagram.backgroundImageURL == nil {
            VStack(spacing: 10) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("尚未匯入桌面照片")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("匯入桌面照片…") { showingImporter = true }
                    .controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .underPageBackgroundColor))
        } else {
            GeometryReader { geometry in
                let rect = contentRect(in: geometry.size)
                ZStack {
                    background(in: rect)
                    ForEach(Array(nodes.enumerated()), id: \.element.key) { index, node in
                        PhotoMarkerView(node: node)
                            .position(position(for: node.key, index: index, in: rect))
                            .gesture(dragGesture(for: node.key, in: rect))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(nsColor: .underPageBackgroundColor))
            .clipped()
        }
    }

    private var photoBar: some View {
        @Bindable var diagram = appState.diagram
        return VStack(spacing: 6) {
            if appState.diagram.backgroundImageURL != nil {
                HStack(spacing: 6) {
                    Image(systemName: "tag")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    TextField("照明情境（例：白天，窗簾拉開）", text: $diagram.backgroundLabel)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .help("寫下這張照片的照明情境。照片是自動曝光的，畫面看不出絕對亮度，也分不出暗處是沒有燈還是燈關著——標註補的正是這段資訊")
                    labelPresetMenu { diagram.backgroundLabel = $0 }
                }
            }
            HStack(spacing: 6) {
                ForEach(appState.advisor.extraPhotos, id: \.self) { url in
                    PhotoThumbnailView(url: url)
                }
                if !appState.advisor.extraPhotos.isEmpty {
                    Text("點縮圖可標註")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if appState.diagram.backgroundImageURL != nil {
                    Button("移除") {
                        appState.diagram.removeBackground()
                        appState.advisor.clearExtraPhotos()
                    }
                    .controlSize(.small)
                }
                Button("匯入…") { showingImporter = true }
                    .controlSize(.small)
                    .help("可一次選多張（最多 \(LightingAdvisor.maxPhotos) 張）：第一張作為配置圖背景與座標基準，其餘為分析用補充視角。拍不同照明情境（白天／夜晚／只開掛燈）並各自標註，分析會更準")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    /// 常用照明情境的一鍵填入。
    private func labelPresetMenu(_ apply: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(LightingAdvisor.labelSuggestions, id: \.self) { suggestion in
                Button(suggestion) { apply(suggestion) }
            }
        } label: {
            Image(systemName: "text.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .controlSize(.small)
        .help("填入常用的照明情境")
    }

    /// 照片在畫布上實際佔用的矩形（等比縮放置中）；沒有照片時就是整塊畫布。
    /// 節點座標一律以這個矩形為基準——照片是直式而區塊是橫式時，兩側會留白，
    /// 若仍以整塊畫布換算，節點會飄在照片外，送去分析的「照片座標」也就失真。
    private func contentRect(in size: CGSize) -> CGRect {
        guard let url = appState.diagram.backgroundImageURL,
              let image = DiagramImageCache.image(for: url),
              image.size.width > 0, image.size.height > 0
        else { return CGRect(origin: .zero, size: size) }
        let scale = min(size.width / image.size.width, size.height / image.size.height)
        let fitted = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        return CGRect(
            x: (size.width - fitted.width) / 2,
            y: (size.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    /// 背景照完整顯示（不裁切），並描一道邊讓可擺放區域一眼可辨。
    @ViewBuilder
    private func background(in rect: CGRect) -> some View {
        if let url = appState.diagram.backgroundImageURL,
           let image = DiagramImageCache.image(for: url) {
            Image(nsImage: image)
                .resizable()
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    // MARK: - 建議區

    private var advicePane: some View {
        Group {
            if let result = appState.advisor.result {
                AdvicePanelView(result: result) { showAdvice = false }
            } else {
                VStack(spacing: 0) {
                    HStack {
                        paneTitle("建議", systemImage: "lightbulb.max")
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    Divider()
                    VStack(spacing: 10) {
                        Image(systemName: "lightbulb.max")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("尚未有分析結果")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !appState.advisor.history.isEmpty {
                            Button("看上次分析結果") { appState.advisor.showLatestHistory() }
                                .controlSize(.small)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 330, maxWidth: showPhoto ? 400 : .infinity)
    }

    // MARK: - 桌面情境

    private var scenarioMenu: some View {
        Menu {
            ForEach(appState.scenarios.scenarios) { scenario in
                Button {
                    appState.scenarios.switchTo(scenario.id)
                } label: {
                    if scenario.id == appState.scenarios.activeID {
                        Label(scenario.name, systemImage: "checkmark")
                    } else {
                        Text(scenario.name)
                    }
                }
            }
            if !appState.scenarios.scenarios.isEmpty {
                Divider()
            }
            Button("將目前桌面存為新情境…") { showingScenarioName = true }
            if appState.scenarios.activeID != nil {
                Button("更新目前情境（含螢幕組合）") {
                    appState.scenarios.saveLiveIntoActive(refreshSignature: true)
                }
                Button("刪除目前情境", role: .destructive) {
                    appState.scenarios.deleteActive()
                }
            }
        } label: {
            Label(
                appState.scenarios.activeScenario?.name ?? String(localized: "情境"),
                systemImage: "square.3.layers.3d"
            )
        }
        .controlSize(.small)
        .fixedSize()
        .help("桌面情境：各自記住照片、節點位置與亮度設定；接上對應螢幕組合時自動切換")
    }

    // MARK: - 顧問列

    private var engineName: String {
        appState.advisor.registry.activeEngine?.engine.displayName ?? "claude"
    }

    private var advisorBar: some View {
        HStack(spacing: 8) {
            if appState.advisor.isAnalyzing {
                ProgressView()
                    .controlSize(.small)
                Text("分析中…（預期 20–60 秒；若跳出鑰匙圈授權，請選「永遠允許」）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { appState.advisor.cancelAnalysis() }
                    .controlSize(.small)
            } else {
                analyzeButton
                if !appState.advisor.history.isEmpty {
                    Button("上次分析結果") { appState.advisor.showLatestHistory() }
                        .controlSize(.small)
                }
                if let message = appState.advisor.lastErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                        .help(message)
                    errorAssistButton
                }
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// 錯誤訊息旁的協助按鈕：未登入 → 複製登入指令；找不到引擎 → 開設定。
    @ViewBuilder
    private var errorAssistButton: some View {
        switch appState.advisor.lastErrorAssist {
        case let .copyLoginCommand(command):
            Button("複製登入指令") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
            }
            .controlSize(.small)
            .help("複製「\(command)」，到終端機貼上執行完成登入後再重試")
        case .openEngineSettings:
            SettingsLink { Text("開啟設定") }
                .controlSize(.small)
                .help("設定 → 分析引擎：確認 CLI 已安裝或指定路徑")
        case nil:
            EmptyView()
        }
    }

    @ViewBuilder
    private var analyzeButton: some View {
        if appState.advisor.registry.activeEngine == nil {
            SettingsLink {
                Label("未找到分析引擎", systemImage: "exclamationmark.triangle")
            }
            .controlSize(.small)
            .help("開啟設定 → 分析引擎，確認 CLI 已安裝或指定路徑")
        } else {
            Button {
                if appState.settings.advisorConfirmed {
                    appState.advisor.analyze()
                } else {
                    showingFirstUseConfirm = true
                }
            } label: {
                Label("分析光環境", systemImage: "lightbulb.max")
            }
            .controlSize(.small)
            .disabled(appState.diagram.backgroundImageURL == nil)
            .help(
                appState.diagram.backgroundImageURL == nil
                    ? "先匯入桌面照片才能分析"
                    : "把照片與裝置配置交給本機 \(engineName) CLI 分析"
            )
        }
    }

    private var footer: some View {
        HStack {
            scenarioMenu
            Text("差異值會疊加在環境基準亮度上")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(10)
    }

    // MARK: - 節點

    private var nodes: [DiagramNode] {
        var result: [DiagramNode] = appState.displayManager.displays.map { display in
            .localDisplay(uuid: display.uuid, name: display.name, isBuiltin: display.isBuiltin)
        }
        result += appState.pairedPeers.peers.map { peer in
            .peer(
                peerID: peer.peerID,
                name: peer.deviceName,
                kind: peer.deviceKind,
                capabilities: peer.capabilities ?? [],
                connected: appState.sessionManager.connectionStates[peer.peerID] == .connected
            )
        }
        return result
    }

    /// 已存座標優先；沒有就以格狀排列給預設位置。座標是照片矩形內的比例。
    private func position(for key: String, index: Int, in rect: CGRect) -> CGPoint {
        let normalized = appState.diagram.position(for: key) ?? defaultPosition(index: index)
        return CGPoint(
            x: rect.minX + normalized.x * rect.width,
            y: rect.minY + normalized.y * rect.height
        )
    }

    private func defaultPosition(index: Int) -> CGPoint {
        let columns = 3
        let column = index % columns
        let row = index / columns
        return CGPoint(x: 0.22 + Double(column) * 0.28, y: 0.25 + Double(row) * 0.32)
    }

    /// 拖曳位置換回照片矩形內的比例（超出範圍由 DiagramStore 夾在 0…1）。
    private func dragGesture(for key: String, in rect: CGRect) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard rect.width > 0, rect.height > 0 else { return }
                appState.diagram.setPosition(
                    CGPoint(
                        x: (value.location.x - rect.minX) / rect.width,
                        y: (value.location.y - rect.minY) / rect.height
                    ),
                    for: key
                )
            }
    }
}

/// 已載入照片的快取：避免拖動節點時每次重繪都從磁碟重讀。
/// 以修改時間一併比對——背景照的檔名固定，換照片時 URL 不變、只有內容變。
@MainActor
enum DiagramImageCache {
    private static var entries: [URL: (modified: Date?, image: NSImage)] = [:]

    static func image(for url: URL) -> NSImage? {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if let entry = entries[url], entry.modified == modified { return entry.image }
        guard let image = NSImage(contentsOf: url) else { return nil }
        entries[url] = (modified, image)
        return image
    }
}

/// 補充照片縮圖：點擊以 popover 放大預覽並編輯這張照片的照明情境標註。
/// 已標註的角落有小標籤，一眼看得出哪幾張還沒寫。
private struct PhotoThumbnailView: View {
    @Environment(AppState.self) private var appState
    let url: URL
    @State private var showingPreview = false

    var body: some View {
        let image = DiagramImageCache.image(for: url)
        let label = appState.advisor.label(for: url)
        Button {
            showingPreview = true
        } label: {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .frame(width: 40, height: 28)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
            .overlay(alignment: .bottomTrailing) {
                if !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Image(systemName: "tag.fill")
                        .font(.system(size: 7))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Color.accentColor, in: Circle())
                        .padding(1)
                }
            }
        }
        .buttonStyle(.plain)
        .help(label.isEmpty ? "尚未標註照明情境；點擊以預覽與標註" : label)
        .popover(isPresented: $showingPreview) {
            VStack(alignment: .leading, spacing: 8) {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 440, maxHeight: 320)
                }
                HStack(spacing: 6) {
                    Image(systemName: "tag")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    TextField("照明情境（例：夜晚，只開掛燈）", text: labelBinding)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(minWidth: 240)
                    Menu {
                        ForEach(LightingAdvisor.labelSuggestions, id: \.self) { suggestion in
                            Button(suggestion) { appState.advisor.setLabel(suggestion, for: url) }
                        }
                    } label: {
                        Image(systemName: "text.badge.plus")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .controlSize(.small)
                }
            }
            .padding(10)
        }
    }

    private var labelBinding: Binding<String> {
        Binding(
            get: { appState.advisor.label(for: url) },
            set: { appState.advisor.setLabel($0, for: url) }
        )
    }
}

/// 配置圖上的一個節點。
enum DiagramNode {
    case localDisplay(uuid: String, name: String, isBuiltin: Bool)
    case peer(peerID: String, name: String, kind: String?, capabilities: [String], connected: Bool)

    var key: String {
        switch self {
        case let .localDisplay(uuid, _, _): "display:\(uuid)"
        case let .peer(peerID, _, _, _, _): "peer:\(peerID)"
        }
    }

    var name: String {
        switch self {
        case let .localDisplay(_, name, _): name
        case let .peer(_, name, _, _, _): name
        }
    }

    var icon: String {
        switch self {
        case let .localDisplay(_, _, isBuiltin): isBuiltin ? "laptopcomputer" : "display"
        case let .peer(_, _, kind, _, _):
            switch kind {
            case "iphone": "iphone"
            case "ipad": "ipad"
            default: "desktopcomputer"
            }
        }
    }
}

/// 照片上的定位標記：只標示是哪台裝置與目前差異值，控制項在配置圖區。
private struct PhotoMarkerView: View {
    @Environment(AppState.self) private var appState
    let node: DiagramNode

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: node.icon)
                .imageScale(.small)
                .foregroundStyle(.secondary)
            Text(node.name)
                .font(.caption2)
                .fontWeight(.medium)
                .lineLimit(1)
            Text(offsetText)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary))
        .shadow(radius: 2, y: 1)
        .fixedSize()
        .help("拖曳以標示這台裝置在桌面上的實際位置")
    }

    private var offsetText: String {
        guard case let .localDisplay(uuid, _, _) = node else { return "" }
        return String(format: "%+.0f%%", (appState.settings.ambientDisplayOffsets[uuid] ?? 0) * 100)
    }
}

/// 配置圖區的裝置卡片：名稱、徽章與亮度差異值滑桿。
private struct DiagramNodeView: View {
    @Environment(AppState.self) private var appState
    let node: DiagramNode

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch node {
            case let .localDisplay(uuid, name, isBuiltin):
                header(
                    icon: isBuiltin ? "laptopcomputer" : "display",
                    name: name,
                    badges: localBadges(uuid: uuid),
                    statusColor: .green
                )
                offsetSlider(
                    value: Binding(
                        get: { appState.settings.ambientDisplayOffsets[uuid] ?? 0 },
                        set: { appState.autoBrightness.setDisplayOffset($0, for: uuid) }
                    ),
                    label: offsetText(appState.settings.ambientDisplayOffsets[uuid] ?? 0),
                    enabled: true
                )
            case let .peer(peerID, name, kind, capabilities, connected):
                header(
                    icon: peerIcon(kind),
                    name: name,
                    badges: peerBadges(capabilities),
                    statusColor: connected ? .green : Color.secondary.opacity(0.4)
                )
                PeerOffsetSlider(peerID: peerID, connected: connected)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(.quaternary)
        )
    }

    private func header(icon: String, name: String, badges: [String], statusColor: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
            }
            if !badges.isEmpty {
                HStack(spacing: 4) {
                    ForEach(badges, id: \.self) { badge in
                        Text(badge)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    private func offsetSlider(value: Binding<Double>, label: String, enabled: Bool) -> some View {
        HStack(spacing: 5) {
            Slider(value: value, in: -0.5...0.5)
                .controlSize(.mini)
                .disabled(!enabled)
            Text(label)
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    private func localBadges(uuid: String) -> [String] {
        var badges: [String] = [String(localized: "本機")]
        if appState.autoBrightness.isAutoActive(for: uuid) { badges.append(String(localized: "自動")) }
        return badges
    }

    private func peerBadges(_ capabilities: [String]) -> [String] {
        capabilities.compactMap { capability in
            switch capability {
            case "als": String(localized: "光感")
            case "display": String(localized: "螢幕")
            case "audio": String(localized: "音訊")
            default: nil
            }
        }
    }

    private func peerIcon(_ kind: String?) -> String {
        switch kind {
        case "iphone": "iphone"
        case "ipad": "ipad"
        default: "desktopcomputer"
        }
    }

    private func offsetText(_ offset: Double) -> String {
        String(format: "%+.0f%%", offset * 100)
    }
}

/// Peer 的整機差異值滑桿：送 setDeviceOffset 給對方。
/// 已知限制：對方目前的差異值不會回讀（同 PeerRemoteControls），滑桿從 0 起。
private struct PeerOffsetSlider: View {
    @Environment(AppState.self) private var appState
    let peerID: String
    let connected: Bool

    @State private var offset = 0.0

    var body: some View {
        HStack(spacing: 5) {
            Slider(
                value: Binding(
                    get: { offset },
                    set: { value in
                        offset = value
                        appState.coordinator.sendDeviceOffset(to: peerID, offset: value)
                    }
                ),
                in: -0.5...0.5
            )
            .controlSize(.mini)
            .disabled(!connected)
            Text(String(format: "%+.0f%%", offset * 100))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .help(connected ? "調整對方的整機亮度差異值" : "離線時無法調整")
    }
}
