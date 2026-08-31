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

        // App 層的等化與效果面板（AU-3）。value＝bundle id；
        // 從選單列 App 列的右鍵開。
        WindowGroup("App 音訊處理", id: "appEffects", for: String.self) { $bundleID in
            if let bundleID {
                AppAudioProcessingView(bundleID: bundleID)
                    .environment(appState)
            }
        }
        .windowResizability(.contentSize)
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
