import SwiftUI

struct VolumeSliderRow: View {
    @Environment(AppState.self) private var appState
    @Bindable var device: AudioDeviceModel
    let manager: AudioDeviceManager

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    manager.setAsDefault(device)
                } label: {
                    Image(systemName: device.isDefault ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(device.isDefault ? Color.accentColor : Color.secondary)
                        .imageScale(.small)
                }
                .buttonStyle(.plain)
                .help("設為預設輸出裝置")

                Text(device.name)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                // 徽章擇一：已橋接時 DDC 已含連接資訊（tooltip 補充），不再疊 transport
                if device.bridgedDisplayID != nil {
                    Text("DDC")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("螢幕音訊（\(device.transportLabel ?? "外接")）：音量經 DDC/CI 控制螢幕喇叭")
                } else if let label = device.transportLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Button {
                    manager.setMuted(!device.muted, for: device)
                } label: {
                    Image(systemName: device.muted ? "speaker.slash" : "speaker.wave.1")
                        .imageScale(.small)
                        .foregroundStyle(.secondary)
                        .frame(width: 16)
                }
                .buttonStyle(.plain)
                .disabled(!device.hasMute && device.bridgedDisplayID == nil)

                Slider(
                    value: Binding(
                        get: { device.volume },
                        set: { manager.setVolume($0, for: device) }
                    ),
                    in: 0...1
                )
                .disabled(!device.isVolumeControllable)
                .help(
                    device.isVolumeControllable
                        ? "調整音量"
                        : "此裝置沒有軟體音量，且未橋接到可用的 DDC 螢幕（螢幕需支援 DDC/CI 音量）"
                )

                Image(systemName: "speaker.wave.3")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(device.volume, format: .percent.precision(.fractionLength(0)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
            }
            // 螢幕音訊沒有 CoreAudio 音量：媒體鍵接管開著時按鍵可用（不需提示）；
            // 沒開才安靜地指路。無法橋接則說明音量不可控。
            if device.isDefault, !device.canSetVolume {
                Group {
                    if device.bridgedDisplayID == nil {
                        Text("此裝置沒有可控音量")
                    } else if !appState.settings.mediaKeyCaptureEnabled {
                        Text("音量鍵對螢幕喇叭無效——設定 → 鍵盤媒體鍵可接管")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 24)
            }
        }
        .contextMenu {
            if manager.isHidden(device) {
                Button("取消隱藏此裝置") { manager.setHidden(false, for: device) }
            } else {
                Button("隱藏此裝置") { manager.setHidden(true, for: device) }
            }
        }
    }
}
