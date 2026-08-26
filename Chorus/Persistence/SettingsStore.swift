import Foundation
import Observation

/// App 設定，存在該 instance 的 UserDefaults suite。
/// 顯示器相關設定以 display UUID 為 key（display ID 重開機會變、UUID 穩定）。
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    private enum Key {
        static let forceSoftwareDimming = "chorus.display.forceSoftwareDimming"
        static let disableDDCRead = "chorus.display.disableDDCRead"
        static let lastBrightness = "chorus.display.lastBrightness"
        static let lastVolume = "chorus.audio.lastVolume"
    }

    /// 強制軟體調光的顯示器 UUID。
    var forceSoftwareDimming: Set<String> {
        didSet { defaults.set(Array(forceSoftwareDimming), forKey: Key.forceSoftwareDimming) }
    }

    /// 停用 DDC read 的顯示器 UUID（部分螢幕 read 會失敗或造成閃爍）。
    var disableDDCRead: Set<String> {
        didSet { defaults.set(Array(disableDDCRead), forKey: Key.disableDDCRead) }
    }

    /// 各顯示器最後設定的亮度（UUID → 0–1），重啟後作為初始值。
    private var lastBrightness: [String: Double] {
        didSet { defaults.set(lastBrightness, forKey: Key.lastBrightness) }
    }

    /// 各音訊裝置最後設定的音量（device UID → 0–1）；DDC 橋接裝置讀不到現值時用。
    private var lastVolume: [String: Double] {
        didSet { defaults.set(lastVolume, forKey: Key.lastVolume) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        forceSoftwareDimming = Set(defaults.stringArray(forKey: Key.forceSoftwareDimming) ?? [])
        disableDDCRead = Set(defaults.stringArray(forKey: Key.disableDDCRead) ?? [])
        lastBrightness = (defaults.dictionary(forKey: Key.lastBrightness) as? [String: Double]) ?? [:]
        lastVolume = (defaults.dictionary(forKey: Key.lastVolume) as? [String: Double]) ?? [:]
    }

    func lastBrightness(for uuid: String) -> Double? {
        lastBrightness[uuid]
    }

    func setLastBrightness(_ value: Double, for uuid: String) {
        lastBrightness[uuid] = value
    }

    func lastVolume(for uid: String) -> Double? {
        lastVolume[uid]
    }

    func setLastVolume(_ value: Double, for uid: String) {
        lastVolume[uid] = value
    }
}
