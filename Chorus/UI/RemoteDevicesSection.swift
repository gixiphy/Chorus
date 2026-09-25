import ChorusCore
import SwiftUI

/// 同步設定裡的「已配對的裝置」：配對、連線狀態、解除配對，以及**逐裝置的
/// 遠端控制開關**。
///
/// 開關放在這裡而不是選單列，是因為兩件事的節奏完全不同：選單列是每天用的
/// 操作介面，「要不要遙控客廳那台的第二台螢幕」是設定一次就不動的決定。
/// 選單列因此只剩下已啟用的項目。
///
/// 首次發現的裝置一律**預設關閉**：既有配對升級時也不依整機能力猜測要開哪些
/// 端點——猜錯的代價是使用者的選單列突然多出一排不認得的滑桿。
struct RemoteDevicesSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section {
            if appState.pairedPeers.peers.isEmpty {
                Text("尚未配對任何裝置")
                    .foregroundStyle(.secondary)
            }
            ForEach(appState.pairedPeers.peers) { peer in
                PairedPeerRow(peer: peer)
            }
            if appState.sessionManager.hasDiscoveryProblem {
                Button {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
                    )
                } label: {
                    Label("無法探索裝置 — 檢查「區域網路」權限", systemImage: "exclamationmark.triangle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("到 系統設定 > 隱私權與安全性 > 區域網路 開啟 Chorus；若清單中沒有 Chorus，重新開機通常可以修復")
            }
        } header: {
            HStack {
                Text("已配對的裝置")
                Spacer()
                Button {
                    openWindow(id: "pairing")
                } label: {
                    Label("配對新裝置", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
            }
        } footer: {
            Text("勾選要在選單列遙控的螢幕與音訊輸出。離線的裝置不會出現在選單列，但設定會保留。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct PairedPeerRow: View {
    @Environment(AppState.self) private var appState
    let peer: PairedPeer

    private var isConnected: Bool {
        appState.sessionManager.connectionStates[peer.peerID] == .connected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(peer.deviceName)
                // 同名 Mac 靠短 peerID 區別——名稱不是資料鍵，改名也不影響歸屬
                Text(ControlGrouping.shortIdentifier(peer.peerID))
                    .font(.caption2)
                    .monospaced()
                    .foregroundStyle(.secondary)
                Spacer()
                Text(statusLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) {
                    appState.pairedPeers.remove(peerID: peer.peerID)
                    appState.sessionManager.restartAdvertiser()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
            }
            if !supportsDirectory {
                Text("這台裝置的 Chorus 版本還不支援逐裝置遙控——更新後才會列出它的螢幕與音訊輸出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                endpointToggles
            }
        }
        .padding(.vertical, 2)
    }

    private var supportsDirectory: Bool {
        // 還沒連過的裝置沒有能力記錄；這時不急著說它不支援。
        peer.capabilities.map { $0.contains(ControlCoordinator.deviceDirectoryCapability) } ?? true
    }

    @ViewBuilder
    private var endpointToggles: some View {
        let rows = endpointRows
        if rows.isEmpty {
            Text(isConnected ? "正在取得裝置清單…" : "離線中——連線後才會列出裝置")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(rows, id: \.id.storageKey) { row in
                HStack(spacing: 6) {
                    Image(systemName: row.id.kind == .display ? "display" : "hifispeaker")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                    Text(row.name)
                        .font(.callout)
                        .foregroundStyle(row.isOnline ? .primary : .secondary)
                    if !row.isOnline {
                        Text("離線")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    // 亮度與音量分開記：「我要遙控那台的螢幕亮度」不代表
                    // 也要遙控它的喇叭。
                    if row.supportsBrightness {
                        Toggle("亮度", isOn: enabledBinding(row.id, capability: .brightness))
                            .toggleStyle(.checkbox)
                    }
                    if row.supportsVolume {
                        Toggle("音量", isOn: enabledBinding(row.id, capability: .volume))
                            .toggleStyle(.checkbox)
                    }
                }
                .padding(.leading, 14)
            }
        }
    }

    private struct EndpointRow {
        let id: RemoteEndpointID
        let name: String
        let isOnline: Bool
        let supportsBrightness: Bool
        let supportsVolume: Bool
    }

    /// 線上的端點來自目前的目錄；離線的從持久化的名稱補回來——
    /// 沒有這一段的話，斷線時整個清單會空掉，使用者連「上次我開了哪些」
    /// 都看不到，更別說把它關掉。
    private var endpointRows: [EndpointRow] {
        let directory = appState.coordinator.remoteDevices.directories[peer.peerID]
        var rows: [EndpointRow] = (directory?.endpoints ?? []).map { endpoint in
            EndpointRow(
                id: RemoteEndpointID(peerID: peer.peerID, kind: endpoint.kind, deviceID: endpoint.deviceID),
                name: endpoint.discriminator.map { "\(endpoint.name)（\($0)）" } ?? endpoint.name,
                isOnline: true,
                supportsBrightness: endpoint.supports(.brightness),
                supportsVolume: endpoint.supports(.volume)
            )
        }
        let online = Set(rows.map(\.id.storageKey))
        let prefix = peer.peerID + "|"
        for (key, name) in appState.settings.remoteEndpointNames
        where key.hasPrefix(prefix) && !online.contains(key) {
            guard let id = RemoteEndpointID(storageKey: key) else { continue }
            rows.append(EndpointRow(
                id: id,
                name: name,
                isOnline: false,
                // 離線時不知道它現在支援什麼，兩個開關都給——使用者要能把
                // 之前開的關掉。
                supportsBrightness: id.kind == .display,
                supportsVolume: id.kind == .audioOutput
            ))
        }
        return rows.sorted { lhs, rhs in
            if lhs.id.kind != rhs.id.kind { return lhs.id.kind == .display }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func enabledBinding(
        _ id: RemoteEndpointID,
        capability: RemoteEndpointCapability
    ) -> Binding<Bool> {
        Binding {
            let set = capability == .brightness
                ? appState.settings.remoteBrightnessEnabled
                : appState.settings.remoteVolumeEnabled
            return set.contains(id.storageKey)
        } set: { enabled in
            var set = capability == .brightness
                ? appState.settings.remoteBrightnessEnabled
                : appState.settings.remoteVolumeEnabled
            if enabled { set.insert(id.storageKey) } else { set.remove(id.storageKey) }
            if capability == .brightness {
                appState.settings.remoteBrightnessEnabled = set
            } else {
                appState.settings.remoteVolumeEnabled = set
            }
        }
    }

    private var statusColor: Color {
        switch appState.sessionManager.connectionStates[peer.peerID] {
        case .connected: .green
        case .connecting: .yellow
        default: Color.secondary.opacity(0.4)
        }
    }

    private var statusLabel: String {
        switch appState.sessionManager.connectionStates[peer.peerID] {
        case .connected: String(localized: "已連線")
        case .connecting: String(localized: "連線中")
        default: String(localized: "離線")
        }
    }
}
