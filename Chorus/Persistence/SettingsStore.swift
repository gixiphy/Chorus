import ChorusCore
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
        static let syncBrightness = "chorus.sync.brightness"
        static let syncVolume = "chorus.sync.volume"
        static let autoBrightness = "chorus.ambient.autoBrightness"
        static let ambientExcludedDisplays = "chorus.ambient.excludedDisplays"
        static let ambientCurve = "chorus.ambient.curve"
        static let ambientDisplayOffsets = "chorus.ambient.displayOffsets"
        static let ambientDeviceOffset = "chorus.ambient.deviceOffset"
        static let hiddenAudioDevices = "chorus.audio.hiddenDevices"
        static let mediaKeyCapture = "chorus.mediaKeys.enabled"
        static let peerKnownControls = "chorus.peer.knownControls"
        static let advisorEngineID = "chorus.advisor.engineID"
        static let advisorCustomPaths = "chorus.advisor.customPaths"
        static let advisorConfirmed = "chorus.advisor.confirmed"
    }

    /// 跨機同步亮度（雙向：不廣播自己的變更、也不套用收到的）。
    var syncBrightnessEnabled: Bool {
        didSet { defaults.set(syncBrightnessEnabled, forKey: Key.syncBrightness) }
    }

    /// 跨機同步音量／靜音。
    var syncVolumeEnabled: Bool {
        didSet { defaults.set(syncVolumeEnabled, forKey: Key.syncVolume) }
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

    /// 自動亮度（環境光感器驅動）總開關。
    var autoBrightnessEnabled: Bool {
        didSet { defaults.set(autoBrightnessEnabled, forKey: Key.autoBrightness) }
    }

    /// 不參與自動亮度的顯示器 UUID。
    var ambientExcludedDisplays: Set<String> {
        didSet { defaults.set(Array(ambientExcludedDisplays), forKey: Key.ambientExcludedDisplays) }
    }

    /// lux → 亮度曲線參數。
    var ambientCurve: AmbientCurve {
        didSet {
            if let data = try? JSONEncoder().encode(ambientCurve) {
                defaults.set(data, forKey: Key.ambientCurve)
            }
        }
    }

    /// 各顯示器的亮度差異值（UUID → -0.5…+0.5），疊加在環境基準之上。
    /// 自動模式下手動調整會「學」進這裡（配置圖也編輯同一份）。
    var ambientDisplayOffsets: [String: Double] {
        didSet { defaults.set(ambientDisplayOffsets, forKey: Key.ambientDisplayOffsets) }
    }

    /// 整機亮度差異值（-0.5…+0.5），peer 可經配置圖遠端調整。
    var ambientDeviceOffset: Double {
        didSet { defaults.set(ambientDeviceOffset, forKey: Key.ambientDeviceOffset) }
    }

    /// 選單列不顯示的音訊裝置 UID（虛擬裝置如 Teams Audio 等）。
    /// 僅影響清單顯示；成為預設輸出時仍會顯示。
    var hiddenAudioDevices: Set<String> {
        didSet { defaults.set(Array(hiddenAudioDevices), forKey: Key.hiddenAudioDevices) }
    }

    /// 媒體鍵接管（需輔助使用權限，預設關閉）。只在 macOS 原生處理走不通的
    /// 情境接手：螢幕喇叭音量鍵、無內建螢幕機器的亮度鍵。
    var mediaKeyCaptureEnabled: Bool {
        didSet { defaults.set(mediaKeyCaptureEnabled, forKey: Key.mediaKeyCapture) }
    }

    /// 各 peer 最後已知的語意層數值（peerID → {"brightness"/"volume" → 0–1}）。
    /// 來源：對方的 stateUpdate/fullState 與我們送出的遙控指令；
    /// 遙控滑桿以此初始化，跨重啟保留（不需要 iCloud——值走既有同步通道）。
    var peerKnownControls: [String: [String: Double]] {
        didSet { defaults.set(peerKnownControls, forKey: Key.peerKnownControls) }
    }

    /// 光環境顧問選定的分析引擎 id（已知 CLI 目錄的 id；預設 claude）。
    var advisorEngineID: String {
        didSet { defaults.set(advisorEngineID, forKey: Key.advisorEngineID) }
    }

    /// 各引擎的自訂執行檔路徑（engine id → path），偵測時優先於 PATH。
    var advisorCustomPaths: [String: String] {
        didSet { defaults.set(advisorCustomPaths, forKey: Key.advisorCustomPaths) }
    }

    /// 首次分析的「照片將交給本機 CLI」確認已被記住。
    var advisorConfirmed: Bool {
        didSet { defaults.set(advisorConfirmed, forKey: Key.advisorConfirmed) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        forceSoftwareDimming = Set(defaults.stringArray(forKey: Key.forceSoftwareDimming) ?? [])
        disableDDCRead = Set(defaults.stringArray(forKey: Key.disableDDCRead) ?? [])
        lastBrightness = (defaults.dictionary(forKey: Key.lastBrightness) as? [String: Double]) ?? [:]
        lastVolume = (defaults.dictionary(forKey: Key.lastVolume) as? [String: Double]) ?? [:]
        syncBrightnessEnabled = defaults.object(forKey: Key.syncBrightness) as? Bool ?? true
        syncVolumeEnabled = defaults.object(forKey: Key.syncVolume) as? Bool ?? true
        autoBrightnessEnabled = defaults.object(forKey: Key.autoBrightness) as? Bool ?? false
        ambientExcludedDisplays = Set(defaults.stringArray(forKey: Key.ambientExcludedDisplays) ?? [])
        if let data = defaults.data(forKey: Key.ambientCurve),
           let curve = try? JSONDecoder().decode(AmbientCurve.self, from: data) {
            ambientCurve = curve
        } else {
            ambientCurve = AmbientCurve()
        }
        ambientDisplayOffsets = (defaults.dictionary(forKey: Key.ambientDisplayOffsets) as? [String: Double]) ?? [:]
        ambientDeviceOffset = defaults.object(forKey: Key.ambientDeviceOffset) as? Double ?? 0
        hiddenAudioDevices = Set(defaults.stringArray(forKey: Key.hiddenAudioDevices) ?? [])
        mediaKeyCaptureEnabled = defaults.bool(forKey: Key.mediaKeyCapture)
        peerKnownControls = (defaults.dictionary(forKey: Key.peerKnownControls) as? [String: [String: Double]]) ?? [:]
        advisorEngineID = defaults.string(forKey: Key.advisorEngineID) ?? "claude"
        advisorCustomPaths = (defaults.dictionary(forKey: Key.advisorCustomPaths) as? [String: String]) ?? [:]
        advisorConfirmed = defaults.bool(forKey: Key.advisorConfirmed)
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
