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
        MenuBarExtra {
            MenuBarView()
                .environment(appState)
        } label: {
            MenuBarLabel()
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
        ChorusLog.app.notice("結束（applicationWillTerminate）")
        MainActor.assumeIsolated {
            // 每一步的耗時寫一行：退出被哪一步拖住（例如 iCloud Drive 卡著）要看得出來
            let metrics = OperationMetrics.shared
            let exitStarted = metrics.now
            var timings: [String] = []
            func timed(_ name: String, _ body: () -> Void) {
                let started = metrics.now
                body()
                timings.append("\(name) \(OperationMetrics.format(metrics.now - started))")
            }
            timed("scenario") { AppStateRegistry.scenarioStore?.saveOnTerminate() }
            // 結束 Chorus 一定還原限時場景（與 B3 的螢幕電源同態度）：
            // 使用者不該因為關掉 Chorus 就被留在「Slack 靜音、螢幕 30%」
            timed("focus") { AppStateRegistry.focus?.shutdown() }
            // 只停排程、不碰 iCloud Drive：CloudDocs 卡住時結束不能跟著卡。
            // 還沒寫出去的變更在 UserDefaults 裡，下次啟動第一拍補上
            timed("cloud") { AppStateRegistry.cloudBackup?.shutdown() }
            timed("display") { AppStateRegistry.displayManager?.shutdown() }
            timed("keepAwake") { AppStateRegistry.keepAwake?.shutdown() }
            ChorusLog.app.notice(
                "結束收尾：\(timings.joined(separator: "、"))（共 \(OperationMetrics.format(metrics.now - exitStarted))）"
            )
            MainLoopWatchdog.shared.logWindowSummary(label: "結束前")
        }
        // 翻譯／顧問還在跑的 CLI：不收的話會被 launchd 收養，一個 150MB 賴著不走
        CLIProcessRunner.killAll()
    }
}
