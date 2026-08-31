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
        //
        // 用 contentMinSize 而不是 contentSize：內容高度會隨建議卡長短
        // 大幅變動，鎖死等於讓視窗自己撐到螢幕外——高度交給使用者，
        // 內容自己捲。
        WindowGroup("App 音訊處理", id: "appEffects", for: String.self) { $bundleID in
            if let bundleID {
                AppAudioProcessingView(bundleID: bundleID)
                    .environment(appState)
            }
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 440, height: 620)
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
