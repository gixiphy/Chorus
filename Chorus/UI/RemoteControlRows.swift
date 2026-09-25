import ChorusCore
import SwiftUI

/// 選單列的「遠端」分類：依 Mac 分組，列出**使用者已啟用**的端點。
///
/// 顯示一列需要六件事同時成立：已配對、目前連線、已取得這條連線的裝置清單、
/// 裝置仍在清單裡、具備對應能力、使用者已在同步設定啟用它。少任何一項就不列
/// ——離線的裝置留在管理介面，不留在操作介面。
struct RemoteControlsSection: View {
    @Environment(AppState.self) private var appState
    let kind: RemoteEndpointKind
    let capability: RemoteEndpointCapability

    var body: some View {
        let groups = peerGroups
        if !groups.isEmpty {
            Text("遠端")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(groups, id: \.peerID) { group in
                VStack(alignment: .leading, spacing: 6) {
                    // Mac 名稱當小標，而不是塞進每一列——「客廳的 Mac mini」
                    // 重複四次會把裝置名稱整個擠掉。
                    HStack(spacing: 5) {
                        Image(systemName: "desktopcomputer")
                            .imageScale(.small)
                        Text(group.name)
                            .font(.caption)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(.secondary)
                    ForEach(group.endpoints, id: \.deviceID) { endpoint in
                        RemoteEndpointSliderRow(
                            id: RemoteEndpointID(
                                peerID: group.peerID,
                                kind: kind,
                                deviceID: endpoint.deviceID
                            ),
                            endpoint: endpoint,
                            capability: capability
                        )
                    }
                }
            }
        }
    }

    private struct PeerGroup {
        let peerID: String
        let name: String
        let endpoints: [RemoteEndpoint]
    }

    /// 同名 Mac 顯示短 peerID——兩台都叫「Mac mini」時，沒有這個就分不出
    /// 正在調的是哪一台。
    private var peerGroups: [PeerGroup] {
        let peers = appState.pairedPeers.peers
        let duplicated = Set(
            Dictionary(grouping: peers, by: \.deviceName)
                .filter { $0.value.count > 1 }
                .keys
        )
        return peers.compactMap { peer in
            guard appState.sessionManager.connectionStates[peer.peerID] == .connected else { return nil }
            let endpoints = enabledEndpoints(of: peer.peerID)
            guard !endpoints.isEmpty else { return nil }
            let name = duplicated.contains(peer.deviceName)
                ? "\(peer.deviceName)（\(ControlGrouping.shortIdentifier(peer.peerID))）"
                : peer.deviceName
            return PeerGroup(peerID: peer.peerID, name: name, endpoints: endpoints)
        }
    }

    private func enabledEndpoints(of peerID: String) -> [RemoteEndpoint] {
        let enabled = capability == .brightness
            ? appState.settings.remoteBrightnessEnabled
            : appState.settings.remoteVolumeEnabled
        return appState.coordinator.remoteDevices
            .endpoints(of: peerID, kind: kind)
            .filter { endpoint in
                guard endpoint.supports(capability) else { return false }
                let key = RemoteEndpointID(peerID: peerID, kind: kind, deviceID: endpoint.deviceID).storageKey
                return enabled.contains(key)
            }
            // 穩定排序：數值每秒更新好幾次，跟著值排會讓滑桿自己跳位置
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// 單一遠端端點的滑桿。
///
/// 值的來源有優先序：拖曳中的待套用值 → 對方確認的現值 → 沒有。
/// 最後一種顯示「—」並停用——不以 50% 之類的猜測值初始化一個**可以操作**
/// 的滑桿，那會讓第一次碰它就把對方的螢幕調到一個沒人要的亮度。
struct RemoteEndpointSliderRow: View {
    @Environment(AppState.self) private var appState
    let id: RemoteEndpointID
    let endpoint: RemoteEndpoint
    let capability: RemoteEndpointCapability

    private var store: RemoteDeviceStore { appState.coordinator.remoteDevices }

    private var value: Double? {
        store.displayValue(id, capability)
    }

    private var failure: RemoteDeviceStore.ControlFailure? {
        store.failure(id, capability)
    }

    /// 同名裝置加上區別後綴（序號末碼或短識別碼）。
    private var displayName: String {
        guard let discriminator = endpoint.discriminator else { return endpoint.name }
        return "\(endpoint.name)（\(discriminator)）"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: capability == .brightness ? "display" : "hifispeaker")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(displayName)
                    .font(.callout)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if endpoint.isDefaultOutput {
                    Text("預設輸出")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            HStack(spacing: SliderRow.spacing) {
                leadingControl
                Slider(
                    value: Binding(
                        get: { value ?? 0 },
                        set: { appState.coordinator.sendEndpointCommand(id, capability: capability, value: $0) }
                    ),
                    in: 0...1
                )
                .disabled(value == nil)
                SliderRow.trailingIcon(capability == .brightness ? "sun.max" : "speaker.wave.3")
                if let value {
                    SliderRow.value(value)
                } else {
                    Text("—")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: SliderRow.valueWidth, alignment: .trailing)
                }
            }
            if let failure {
                Text(failure.message)
                    .font(.caption2)
                    .foregroundStyle(failure.isUnavailable ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, SliderRow.iconWidth + SliderRow.spacing)
            }
        }
    }

    /// 音量列的左端是靜音鈕（對方支援才給）；亮度列是圖示。
    @ViewBuilder
    private var leadingControl: some View {
        if capability == .volume, endpoint.supports(.mute) {
            let muted = store.displayValue(id, .mute).map { $0 > 0.5 } ?? false
            Button {
                appState.coordinator.sendEndpointCommand(id, capability: .mute, value: muted ? 0 : 1)
            } label: {
                Image(systemName: muted ? "speaker.slash" : "speaker.wave.1")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .frame(width: SliderRow.iconWidth)
            }
            .buttonStyle(.plain)
        } else {
            SliderRow.leadingIcon(capability == .brightness ? "sun.min" : "speaker.wave.1")
        }
    }
}
