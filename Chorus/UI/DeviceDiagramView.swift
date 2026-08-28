import SwiftUI
import UniformTypeIdentifiers

/// 照射設備配置圖：可拖拉的裝置節點（本機顯示器＋已配對裝置）擺在畫布上
/// 反映實際擺設，可匯入桌面照片當背景；每個節點提供亮度差異值調整。
/// 差異值語意：疊加在環境基準亮度之上（本機顯示器改 ambientDisplayOffsets、
/// peer 節點送 setDeviceOffset 給對方）。
struct DeviceDiagramView: View {
    @Environment(AppState.self) private var appState
    @State private var showingImporter = false
    @State private var showingFirstUseConfirm = false
    @State private var showingScenarioName = false
    @State private var newScenarioName = ""

    var body: some View {
        @Bindable var advisor = appState.advisor
        VStack(spacing: 0) {
            canvas
            Divider()
            advisorBar
            Divider()
            footer
        }
        .frame(minWidth: 560, minHeight: 400)
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
        .sheet(item: $advisor.result) { result in
            AdviceSheetView(result: result)
                .environment(appState)
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
                appState.scenarios.activeScenario?.name ?? "情境",
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
                if !appState.advisor.extraPhotos.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(appState.advisor.extraPhotos, id: \.self) { url in
                            PhotoThumbnailView(url: url)
                        }
                    }
                    .help("補充照片：分析時與背景照一併提供（點擊可放大）")
                }
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

    private var canvas: some View {
        GeometryReader { geometry in
            let rect = contentRect(in: geometry.size)
            ZStack {
                background(in: rect)
                ForEach(Array(nodes.enumerated()), id: \.element.key) { index, node in
                    DiagramNodeView(node: node)
                        .position(position(for: node.key, index: index, in: rect))
                        .gesture(dragGesture(for: node.key, in: rect))
                }
                if nodes.isEmpty {
                    Text("沒有可顯示的裝置")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .underPageBackgroundColor))
        .clipped()
    }

    /// 照片在畫布上實際佔用的矩形（等比縮放置中）；沒有照片時就是整塊畫布。
    /// 節點座標一律以這個矩形為基準——照片是直式而視窗是橫式時，兩側會留白，
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
            // 節點卡片有 material 底，照片可以清楚顯示；留一點淡化避免搶走節點。
            Image(nsImage: image)
                .resizable()
                .opacity(0.85)
                .frame(width: rect.width, height: rect.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                .position(x: rect.midX, y: rect.midY)
                .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        HStack {
            scenarioMenu
            Text("拖拉節點擺放實際位置；差異值會疊加在環境基準亮度上")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            if appState.diagram.backgroundImageURL != nil {
                Button("移除照片") {
                    appState.diagram.removeBackground()
                    appState.advisor.clearExtraPhotos()
                }
                .controlSize(.small)
            }
            Button("匯入桌面照片…") { showingImporter = true }
                .controlSize(.small)
                .help("可一次選多張（最多 \(LightingAdvisor.maxPhotos) 張）：第一張作為配置圖背景與座標基準，其餘為分析用補充視角")
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
private enum DiagramImageCache {
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

/// 補充照片縮圖：點擊以 popover 放大預覽（完整照片，不裁切）。
private struct PhotoThumbnailView: View {
    let url: URL
    @State private var showingPreview = false

    var body: some View {
        let image = DiagramImageCache.image(for: url)
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
            .frame(width: 44, height: 30)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.quaternary))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingPreview) {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 520, maxHeight: 390)
                    .padding(6)
            }
        }
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
}

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
        .frame(width: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary)
        )
        .shadow(radius: 2, y: 1)
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
        var badges: [String] = ["本機"]
        if appState.autoBrightness.isAutoActive(for: uuid) { badges.append("自動") }
        return badges
    }

    private func peerBadges(_ capabilities: [String]) -> [String] {
        capabilities.compactMap { capability in
            switch capability {
            case "als": "光感"
            case "display": "螢幕"
            case "audio": "音訊"
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
