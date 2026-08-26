import SwiftUI

struct DisplaySliderRow: View {
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
