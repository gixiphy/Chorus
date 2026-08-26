import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Chorus")
                    .font(.headline)
                Spacer()
                if let name = appState.instance.name {
                    Text(name)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(.plain)
            }

            Divider()

            if appState.displayManager.displays.isEmpty {
                Text("找不到可控制的顯示器")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(appState.displayManager.displays) { display in
                        DisplaySliderRow(model: display, manager: appState.displayManager)
                    }
                }
            }

            Divider()

            Button("結束 Chorus") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
        }
        .padding(12)
        .frame(width: 300)
    }
}

#Preview {
    MenuBarView()
        .environment(AppState())
}
