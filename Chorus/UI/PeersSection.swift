import SwiftUI

struct PeersSection: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("已配對的 Mac")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    openWindow(id: "diagram")
                } label: {
                    Image(systemName: "rectangle.3.group")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("裝置配置圖")
                Button {
                    openWindow(id: "pairing")
                } label: {
                    Image(systemName: "plus.circle")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("配對新裝置")
            }
            if appState.sessionManager.hasDiscoveryProblem {
                Button {
                    NSWorkspace.shared.open(
                        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
                    )
                } label: {
                    Label("無法探索裝置 — 檢查「區域網路」權限", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("到 系統設定 > 隱私權與安全性 > 區域網路 開啟 Chorus；若清單中沒有 Chorus，重新開機通常可以修復")
            }
            if appState.pairedPeers.peers.isEmpty {
                Text("尚未配對任何裝置")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.pairedPeers.peers) { peer in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(statusColor(peer.peerID))
                                .frame(width: 7, height: 7)
                            Text(peer.deviceName)
                                .font(.callout)
                            Spacer()
                            Text(statusLabel(peer.peerID))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        if appState.sessionManager.connectionStates[peer.peerID] == .connected {
                            PeerRemoteControls(peerID: peer.peerID)
                        }
                    }
                }
            }
        }
    }

    private func statusColor(_ peerID: String) -> Color {
        switch appState.sessionManager.connectionStates[peerID] {
        case .connected: .green
        case .connecting: .yellow
        default: Color.secondary.opacity(0.4)
        }
    }

    private func statusLabel(_ peerID: String) -> String {
        switch appState.sessionManager.connectionStates[peerID] {
        case .connected: "已連線"
        case .connecting: "連線中"
        default: "離線"
        }
    }
}

/// 遙控已連線 peer 的亮度與音量（送出絕對值 command）。
private struct PeerRemoteControls: View {
    @Environment(AppState.self) private var appState
    let peerID: String

    @State private var brightness = 0.5
    @State private var volume = 0.5

    private var brightnessBinding: Binding<Double> {
        Binding {
            brightness
        } set: { value in
            brightness = value
            appState.coordinator.sendRemoteCommand(
                to: peerID, key: .brightness(displayUUID: nil), value: value
            )
        }
    }

    private var volumeBinding: Binding<Double> {
        Binding {
            volume
        } set: { value in
            volume = value
            appState.coordinator.sendRemoteCommand(
                to: peerID, key: .volume(deviceUID: nil), value: value
            )
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "sun.max")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Slider(value: brightnessBinding, in: 0...1)
                    .controlSize(.mini)
            }
            HStack(spacing: 8) {
                Image(systemName: "speaker.wave.2")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Slider(value: volumeBinding, in: 0...1)
                    .controlSize(.mini)
            }
        }
        .padding(.leading, 13)
    }
}
