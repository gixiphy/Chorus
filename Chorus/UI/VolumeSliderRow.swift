import SwiftUI

struct VolumeSliderRow: View {
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
                if let label = device.transportLabel {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if device.bridgedDisplayID != nil {
                    Text("DDC")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
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
