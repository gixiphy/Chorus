import Foundation
import Observation

/// App 的根狀態，只在 MainActor 上讀寫。
@MainActor
@Observable
final class AppState {
    let instance: InstanceConfig
    let settings: SettingsStore
    let displayManager: DisplayManager

    init(instance: InstanceConfig = .current) {
        self.instance = instance
        let settings = SettingsStore(defaults: instance.defaults)
        self.settings = settings
        displayManager = DisplayManager(settings: settings)
        displayManager.start()
    }
}
