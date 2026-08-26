import Foundation
import Observation

/// App 的根狀態，只在 MainActor 上讀寫。
@MainActor
@Observable
final class AppState {
    let instance: InstanceConfig

    init(instance: InstanceConfig = .current) {
        self.instance = instance
    }
}
