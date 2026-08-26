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
                    openWindow(id: "pairing")
                } label: {
                    Image(systemName: "plus.circle")
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("配對新裝置")
            }
            if appState.pairedPeers.peers.isEmpty {
                Text("尚未配對任何裝置")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.pairedPeers.peers) { peer in
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
