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
        // 高度由 view 自己量內容決定並設上限（AppAudioProcessingView
        // 的 scrollHeight），這裡用 contentSize 讓視窗貼著那個尺寸——
        // 可調整大小的話，上一次開過的過高視窗框會被還原回來，
        // 內容縮短也不會跟著收。
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
