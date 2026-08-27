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
        .fileImporter(
            isPresented: $showingImporter,
            allowedContentTypes: [.image]
        ) { result in
            if case let .success(url) = result {
                let accessing = url.startAccessingSecurityScopedResource()
                appState.diagram.importBackground(from: url)
                if accessing { url.stopAccessingSecurityScopedResource() }
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
        .onAppear { appState.advisor.loadHistoryIfNeeded() }
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
                Text("分析中…（CLI 冷啟與推理較慢，預期 20–60 秒）")
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
                }
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
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
            ZStack {
                background
                ForEach(Array(nodes.enumerated()), id: \.element.key) { index, node in
                    DiagramNodeView(node: node)
                        .position(position(for: node.key, index: index, in: geometry.size))
                        .gesture(dragGesture(for: node.key, in: geometry.size))
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

    @ViewBuilder
    private var background: some View {
        if let url = appState.diagram.backgroundImageURL,
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .opacity(0.35)
                .allowsHitTesting(false)
        }
    }

    private var footer: some View {
        HStack {
            Text("拖拉節點擺放實際位置；差異值會疊加在環境基準亮度上")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if appState.diagram.backgroundImageURL != nil {
                Button("移除照片") { appState.diagram.removeBackground() }
                    .controlSize(.small)
            }
            Button("匯入桌面照片…") { showingImporter = true }
                .controlSize(.small)
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

    /// 已存座標優先；沒有就以格狀排列給預設位置。
    private func position(for key: String, index: Int, in size: CGSize) -> CGPoint {
        let normalized = appState.diagram.position(for: key) ?? defaultPosition(index: index)
        return CGPoint(x: normalized.x * size.width, y: normalized.y * size.height)
    }

    private func defaultPosition(index: Int) -> CGPoint {
        let columns = 3
        let column = index % columns
        let row = index / columns
        return CGPoint(x: 0.22 + Double(column) * 0.28, y: 0.25 + Double(row) * 0.32)
    }

    private func dragGesture(for key: String, in size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard size.width > 0, size.height > 0 else { return }
                appState.diagram.setPosition(
                    CGPoint(x: value.location.x / size.width, y: value.location.y / size.height),
                    for: key
                )
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
