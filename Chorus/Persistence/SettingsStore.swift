import ChorusCore
import Foundation
import Observation

/// App 設定，存在該 instance 的 UserDefaults suite。
/// 顯示器相關設定以 display UUID 為 key（display ID 重開機會變、UUID 穩定）。
@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    /// 拖桿路徑（音量／亮度／逐 App 表／EQ）的持久化去抖。這些值在拖動
    /// 時每秒寫 30–60 次，逐筆 JSON encode ＋ XPC 給 cfprefsd 是純浪費
    /// ——記憶體裡的值才是權威，defaults 只要拿到尾端那筆。App 被殺
    /// 最多丟半秒的滑桿位置，這些鍵都只是「上次的值」，可以承受。
    @ObservationIgnored private var pendingPersists: [String: Task<Void, Never>] = [:]
    private func persistDebounced(_ key: String, _ write: @escaping @MainActor () -> Void) {
        pendingPersists[key]?.cancel()
        pendingPersists[key] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            write()
            self?.pendingPersists[key] = nil
        }
    }

    private enum Key {
        static let forceSoftwareDimming = "chorus.display.forceSoftwareDimming"
        static let subZeroDimming = "chorus.display.subZeroDimming"
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
        static let audioBridgeDisabled = "chorus.audio.bridgeDisabled"
        static let peerKnownControls = "chorus.peer.knownControls"
        static let advisorEngineID = "chorus.advisor.engineID"
        static let advisorCustomPaths = "chorus.advisor.customPaths"
        static let advisorConfirmed = "chorus.advisor.confirmed"
        static let advisorModelIDs = "chorus.advisor.modelIDs"
        static let advisorModelCache = "chorus.advisor.modelCache"
        static let audioTaps = "chorus.audio.tapsEnabled"
        static let appAudio = "chorus.audio.appSettings"
        static let softwareVolume = "chorus.audio.softwareVolumeDevices"
        static let deviceEQ = "chorus.audio.deviceEQ"
        static let deviceEffects = "chorus.audio.deviceEffects"
        static let effectQuarantine = "chorus.audio.effectQuarantine"
        static let effectPendingLoad = "chorus.audio.effectPendingLoad"
        static let outputPriority = "chorus.audio.outputPriority"
        static let keepAwakeSystemSleep = "chorus.keepAwake.preventSystemSleep"
        static let keepAwakeDisplayUUID = "chorus.keepAwake.displayUUID"
        static let virtualTargetUID = "chorus.audio.virtualTargetUID"
        static let automationServer = "chorus.automation.serverEnabled"
        static let automationPort = "chorus.automation.serverPort"
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

    /// Sub-zero dimming 的顯示器 UUID：滑桿下段先讓硬體亮度到底、
    /// 再以 gamma 繼續變暗（外接螢幕的硬體 0 常常還是很亮）。
    var subZeroDimming: Set<String> {
        didSet { defaults.set(Array(subZeroDimming), forKey: Key.subZeroDimming) }
    }

    /// 停用 DDC read 的顯示器 UUID（部分螢幕 read 會失敗或造成閃爍）。
    var disableDDCRead: Set<String> {
        didSet { defaults.set(Array(disableDDCRead), forKey: Key.disableDDCRead) }
    }

    /// 各顯示器最後設定的亮度（UUID → 0–1），重啟後作為初始值。
    private var lastBrightness: [String: Double] {
        didSet {
            persistDebounced(Key.lastBrightness) { [weak self] in
                guard let self else { return }
                self.defaults.set(self.lastBrightness, forKey: Key.lastBrightness)
            }
        }
    }

    /// 各音訊裝置最後設定的音量（device UID → 0–1）；DDC 橋接裝置讀不到現值時用。
    private var lastVolume: [String: Double] {
        didSet {
            persistDebounced(Key.lastVolume) { [weak self] in
                guard let self else { return }
                self.defaults.set(self.lastVolume, forKey: Key.lastVolume)
            }
        }
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

    /// 使用者標記「螢幕不支援 DDC 音量」的音訊裝置 UID：不再嘗試橋接，
    /// 滑桿誠實地停用（實測 Q34E2G5 亮度支援 0x10 但音量 0x62 寫讀皆不通）。
    var audioBridgeDisabled: Set<String> {
        didSet { defaults.set(Array(audioBridgeDisabled), forKey: Key.audioBridgeDisabled) }
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

    /// 各引擎的自訂模型字串（engine id → 模型名）。留空＝用 CLI 自己的預設。
    ///
    /// 刻意**不做**「執行 `<cli> models` 列出可選項」：只有 agy 有這種指令，
    /// 而它實測會無限期卡住（1.1.22）；其餘 CLI 根本沒有列舉介面。
    /// 一個自由輸入欄位對五個引擎都成立，也不必為了一份清單去打網路。
    var advisorModelIDs: [String: String] {
        didSet { defaults.set(advisorModelIDs, forKey: Key.advisorModelIDs) }
    }

    /// 模型清單快取（"engineID|version" → slugs）。以 CLI 版本為鍵：
    /// 版本沒變就用快取，升版即重抓——列舉要打網路，不該每次開設定頁都跑。
    var advisorModelCache: [String: [String]] {
        didSet { defaults.set(advisorModelCache, forKey: Key.advisorModelCache) }
    }

    /// Process tap 引擎（per-app 音量的基礎設施，B6）。**預設關閉**
    /// （權限功能紀律）；開啟時走 DESIGN-M12 §1.2 的權限流程。
    var audioTapsEnabled: Bool {
        didSet { defaults.set(audioTapsEnabled, forKey: Key.audioTaps) }
    }

    /// 逐 App 的音量／靜音／路由（bundle id → 設定，B6-2）。
    /// 只存「有調整過」的 App——歸零就從表裡消失，因此這份表同時就是
    /// 「哪些 App 需要 tap」的清單（DESIGN §2.3 規則 2）。
    ///
    /// 存 JSON 而不是 plist 字典：`AppAudioSetting` 之後還會長欄位
    /// （B6-3 路由、B6-5 EQ），Codable 的往返比手工拆字典可靠。
    var appAudio: AppAudioSettings {
        didSet {
            persistDebounced(Key.appAudio) { [weak self] in
                guard let self, let data = try? JSONEncoder().encode(self.appAudio) else { return }
                self.defaults.set(data, forKey: Key.appAudio)
            }
        }
    }

    /// 使用者為哪些裝置開啟了「軟體音量」（三後端矩陣第三條，B6-4）。
    /// **預設不啟用**：它會讓該裝置的所有音訊繞道 Chorus，多一個 buffer
    /// 的延遲（實測 ~10.7 ms）——這個代價要由使用者明確決定，
    /// 不是我們替沒有硬體音量的裝置自動打開。
    var softwareVolumeDevices: Set<String> {
        didSet { defaults.set(Array(softwareVolumeDevices), forKey: Key.softwareVolume) }
    }

    /// 每輸出裝置的等化設定（device UID → EQ，B6-5）。**預設關閉**：
    /// EQ 一開就代表該裝置的所有音訊要繞道 Chorus，與軟體音量同一個代價。
    ///
    /// 以 device UID 為鍵而不是名稱：同型號兩支耳機的名稱一樣，
    /// 而 AutoEq 校正是綁在**那一支**上的。
    var deviceEQ: [String: EQSettings] {
        didSet {
            persistDebounced(Key.deviceEQ) { [weak self] in
                guard let self, let data = try? JSONEncoder().encode(self.deviceEQ) else { return }
                self.defaults.set(data, forKey: Key.deviceEQ)
            }
        }
    }

    /// 每裝置的 AU 效果鏈（B6-8）。與 deviceEQ 同一個責任層與代價：
    /// 鏈非空＝該裝置的所有音訊繞道 Chorus。順序即處理順序。
    var deviceEffects: [String: [AUEffectEntry]] {
        didSet {
            guard let data = try? JSONEncoder().encode(deviceEffects) else { return }
            defaults.set(data, forKey: Key.deviceEffects)
        }
    }

    /// 被隔離的 AU 元件 key（上次載入時把 App 帶走的那些）。
    /// 解除隔離是使用者的明確動作，不自動過期。
    var effectQuarantine: Set<String> {
        didSet { defaults.set(Array(effectQuarantine).sorted(), forKey: Key.effectQuarantine) }
    }

    /// 隔離閂：目前正在載入的元件 key。實例化前寫、成功後清；
    /// 啟動時發現殘留＝上次載它時崩潰 → 收養進 effectQuarantine。
    var effectPendingLoad: String? {
        didSet { defaults.set(effectPendingLoad, forKey: Key.effectPendingLoad) }
    }

    /// 輸出裝置的偏好順位（device UID，前面優先，B6-7）。**空陣列＝功能關閉**。
    ///
    /// 有順位時：偏好的裝置一接上就自動成為預設輸出，並還原它上次的音量。
    /// 只在**裝置清單真的變動**時作用——否則使用者手動選了別的裝置，
    /// 下一個 snapshot 就會被我們搶回去。
    var outputPriority: [String] {
        didSet { defaults.set(outputPriority, forKey: Key.outputPriority) }
    }

    /// 螢幕長亮時是否連系統待機一起擋（預設只擋螢幕待機）。
    var keepAwakePreventsSystemSleep: Bool {
        didSet { defaults.set(keepAwakePreventsSystemSleep, forKey: Key.keepAwakeSystemSleep) }
    }

    /// 「接著這台螢幕時防睡眠」綁定的顯示器 UUID。
    /// 只有這個模式跨重啟保留——計時與無限期是當下的臨時決定，
    /// 重開機還幫使用者擋睡眠是意料之外的行為。
    var keepAwakeDisplayUUID: String? {
        didSet { defaults.set(keepAwakeDisplayUUID, forKey: Key.keepAwakeDisplayUUID) }
    }

    /// 虛擬輸出裝置的轉送目標：**nil＝自動**（跟著使用中的螢幕走，都沒有就
    /// 回內建輸出）。指定 UID 則固定送那台——但它不在時仍會自動退回，
    /// 不會讓聲音消失；它回來時再接回去。
    var virtualTargetUID: String? {
        didSet { defaults.set(virtualTargetUID, forKey: Key.virtualTargetUID) }
    }

    /// localhost 自動化 HTTP 介面。**預設關閉**（權限功能紀律）；
    /// 開啟時才生成 token。
    var automationServerEnabled: Bool {
        didSet { defaults.set(automationServerEnabled, forKey: Key.automationServer) }
    }

    /// 自動化介面的 port。預設 55780——BetterDisplay 用 55777，刻意避開，
    /// 兩個都裝的人才不會撞。
    var automationServerPort: UInt16 {
        didSet { defaults.set(Int(automationServerPort), forKey: Key.automationPort) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        forceSoftwareDimming = Set(defaults.stringArray(forKey: Key.forceSoftwareDimming) ?? [])
        subZeroDimming = Set(defaults.stringArray(forKey: Key.subZeroDimming) ?? [])
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
        audioBridgeDisabled = Set(defaults.stringArray(forKey: Key.audioBridgeDisabled) ?? [])
        peerKnownControls = (defaults.dictionary(forKey: Key.peerKnownControls) as? [String: [String: Double]]) ?? [:]
        advisorEngineID = defaults.string(forKey: Key.advisorEngineID) ?? "claude"
        advisorCustomPaths = (defaults.dictionary(forKey: Key.advisorCustomPaths) as? [String: String]) ?? [:]
        advisorConfirmed = defaults.bool(forKey: Key.advisorConfirmed)
        advisorModelIDs = (defaults.dictionary(forKey: Key.advisorModelIDs) as? [String: String]) ?? [:]
        advisorModelCache = (defaults.dictionary(forKey: Key.advisorModelCache) as? [String: [String]]) ?? [:]
        audioTapsEnabled = defaults.bool(forKey: Key.audioTaps)
        if let data = defaults.data(forKey: Key.appAudio),
           let decoded = try? JSONDecoder().decode(AppAudioSettings.self, from: data) {
            appAudio = decoded
        } else {
            appAudio = AppAudioSettings()
        }
        softwareVolumeDevices = Set(defaults.stringArray(forKey: Key.softwareVolume) ?? [])
        if let data = defaults.data(forKey: Key.deviceEQ),
           let decoded = try? JSONDecoder().decode([String: EQSettings].self, from: data) {
            deviceEQ = decoded
        } else {
            deviceEQ = [:]
        }
        if let data = defaults.data(forKey: Key.deviceEffects),
           let decoded = try? JSONDecoder().decode([String: [AUEffectEntry]].self, from: data) {
            deviceEffects = decoded
        } else {
            deviceEffects = [:]
        }
        // 隔離閂的收養（DESIGN-20260830-au-hosting §1.1）：殘留的載入中
        // key ＝ 上次載那個外掛時整個 App 被帶走 → 進隔離名單
        let adopted = EffectQuarantine.adopt(
            pendingLoadKey: defaults.string(forKey: Key.effectPendingLoad),
            into: Set(defaults.stringArray(forKey: Key.effectQuarantine) ?? [])
        )
        effectQuarantine = adopted
        defaults.set(Array(adopted).sorted(), forKey: Key.effectQuarantine)
        effectPendingLoad = nil
        defaults.removeObject(forKey: Key.effectPendingLoad)
        outputPriority = defaults.stringArray(forKey: Key.outputPriority) ?? []
        keepAwakePreventsSystemSleep = defaults.bool(forKey: Key.keepAwakeSystemSleep)
        keepAwakeDisplayUUID = defaults.string(forKey: Key.keepAwakeDisplayUUID)
        virtualTargetUID = defaults.string(forKey: Key.virtualTargetUID)
        automationServerEnabled = defaults.bool(forKey: Key.automationServer)
        automationServerPort = UInt16(defaults.object(forKey: Key.automationPort) as? Int ?? 55780)
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
