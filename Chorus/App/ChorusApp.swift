import SwiftUI

@main
struct ChorusApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra("Chorus", systemImage: "rays") {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(appState)
        }
    }
}
