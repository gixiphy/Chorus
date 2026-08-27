import SwiftUI

struct DisplaySliderRow: View {
    @Environment(AppState.self) private var appState
    @Bindable var model: DisplayModel
    let manager: DisplayManager

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: model.isBuiltin ? "laptopcomputer" : "display")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
                Text(model.name)
                    .font(.callout)
                Spacer()
                if appState.autoBrightness.isAutoActive(for: model.uuid) {
                    Text("自動")
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: Capsule())
                        .help("自動亮度管理中；手動調整會學為此螢幕的差異值")
                }
                if !model.hasHardwareControl {
                    Text("軟體調光")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Slider(
                    value: Binding(
                        get: { model.brightness },
                        set: { manager.setBrightness($0, for: model) }
                    ),
                    in: 0...1
                )
                Image(systemName: "sun.max")
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
