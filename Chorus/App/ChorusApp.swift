import SwiftUI

@main
struct ChorusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState

    init() {
        let state = AppState()
        _appState = State(initialValue: state)
        #if DEBUG
        TestSupport.hooks = TestHooks(appState: state)
        #endif
    }

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

        Window("配對新裝置", id: "pairing") {
            PairingView()
                .environment(appState)
        }
        .windowResizability(.contentSize)

        Window("裝置配置", id: "diagram") {
            DeviceDiagramView()
                .environment(appState)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppStateRegistry.scenarioStore?.saveOnTerminate()
            AppStateRegistry.displayManager?.shutdown()
            AppStateRegistry.keepAwake?.shutdown()
        }
    }
}
