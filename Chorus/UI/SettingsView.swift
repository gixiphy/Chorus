import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("一般", systemImage: "gearshape") {
                Form {
                    Text("設定內容將於後續里程碑加入")
                        .foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            }
        }
        .frame(width: 440, height: 320)
    }
}

#Preview {
    SettingsView()
}
