import SwiftUI

struct PairingView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 16) {
            content
        }
        .padding(24)
        .frame(width: 380, height: 320)
        .onAppear { appState.pairing.begin() }
        .onDisappear { appState.pairing.end() }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.pairing.phase {
        case .idle, .browsing:
            browsingView
        case let .awaitingResponse(peerName):
            VStack(spacing: 12) {
                ProgressView()
                Text("等待「\(peerName)」接受配對…")
                Button("取消") { appState.pairing.cancelPairing() }
            }
        case let .incomingRequest(peerName):
            VStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.largeTitle)
                Text("「\(peerName)」想要與這台 Mac 配對")
                HStack {
                    Button("拒絕") { appState.pairing.declineIncoming() }
                    Button("接受") { appState.pairing.acceptIncoming() }
                        .buttonStyle(.borderedProminent)
                }
            }
        case let .showingSAS(code, peerName, localConfirmed, remoteConfirmed):
            VStack(spacing: 12) {
                Text("確認兩台 Mac 顯示相同的配對碼")
                    .font(.headline)
                Text(code)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .kerning(6)
                Text("與「\(peerName)」配對")
                    .foregroundStyle(.secondary)
                if localConfirmed {
                    Label(
                        remoteConfirmed ? "雙方已確認" : "等待對方確認…",
                        systemImage: remoteConfirmed ? "checkmark.circle" : "hourglass"
                    )
                    .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("不相符") { appState.pairing.cancelPairing() }
                        Button("相符") { appState.pairing.confirmSAS() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        case let .completed(peerName):
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)
                Text("已與「\(peerName)」配對完成")
                Button("繼續配對其他裝置") {
                    appState.pairing.end()
                    appState.pairing.begin()
                }
            }
        case let .failed(reason):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text("配對失敗：\(reason)")
                Button("重試") {
                    appState.pairing.end()
                    appState.pairing.begin()
                }
            }
        }
    }

    private var browsingView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("在另一台 Mac 上也打開「配對新裝置」視窗", systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
            Divider()
            if appState.pairing.candidates.isEmpty {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在尋找附近的 Mac…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(appState.pairing.candidates) { candidate in
                    HStack {
                        Image(systemName: "desktopcomputer")
                        Text(candidate.name)
                        Spacer()
                        Button("配對") {
                            appState.pairing.requestPair(with: candidate)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}
