import ChorusCore
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
///
/// 滑桿位置直接讀「對方回報的現值」（`peerKnownControls`）——以前是開啟
/// 選單時複製一份到 @State 就不再更新，對方自己動過（或我們上次連線是
/// 好幾天前）就會顯示錯的值。現值來源有三條：對方變更時的 stateUpdate、
/// 任何變更都會發的 stateReport，以及這個 view 出現時主動送的 stateQuery。
private struct PeerRemoteControls: View {
    @Environment(AppState.self) private var appState
    let peerID: String

    private var known: [String: Double] {
        appState.settings.peerKnownControls[peerID] ?? [:]
    }

    private func binding(_ field: String, key: ControlKey) -> Binding<Double> {
        Binding {
            known[field] ?? 0.5
        } set: { value in
            appState.coordinator.sendRemoteCommand(to: peerID, key: key, value: value)
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: SliderRow.spacing) {
                SliderRow.leadingIcon("sun.min")
                Slider(value: binding("brightness", key: .brightness(displayUUID: nil)), in: 0...1)
                SliderRow.trailingIcon("sun.max")
                value(known["brightness"])
            }
            HStack(spacing: SliderRow.spacing) {
                SliderRow.leadingIcon(known["muted"] == 1 ? "speaker.slash" : "speaker.wave.1")
                Slider(value: binding("volume", key: .volume(deviceUID: nil)), in: 0...1)
                SliderRow.trailingIcon("speaker.wave.3")
                value(known["volume"])
            }
        }
        // 對方可能在斷線期間自己調過（或跑舊版不會主動回報）——每次顯示
        // 都問一次，答案幾毫秒內就會回來並更新滑桿。
        .onAppear { appState.coordinator.requestPeerState(from: peerID) }
    }

    /// 還沒收到任何回報時不要假裝知道：顯示「—」而不是一個編出來的數字。
    @ViewBuilder
    private func value(_ known: Double?) -> some View {
        if let known {
            SliderRow.value(known)
        } else {
            Text("—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: SliderRow.valueWidth, alignment: .trailing)
        }
    }
}
