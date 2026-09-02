import Foundation

/// 版本化的快照。比這個 build 認得的還新就**不要硬套**——套下去會把設定
/// 改成半套，比不套更難查。（架構參考 Foldwall 0.7.0 的 `VersionedSnapshot`。）
public protocol VersionedSnapshot: Codable, Sendable {
    static var currentVersion: Int { get }
    var version: Int { get }
}

public enum BackupCodec {
    public enum Failure: Error, Equatable {
        case unsupportedVersion(Int)
    }

    /// JSON 往返。**人看得懂是刻意的**：檔案就躺在使用者自己的 iCloud Drive
    /// 裡，出事時他要能打開看發生什麼事，必要時自己改一行。
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    public static func decode<T: VersionedSnapshot>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let value = try decoder.decode(T.self, from: data)
        guard value.version <= T.currentVersion else {
            throw Failure.unsupportedVersion(value.version)
        }
        return value
    }
}

/// 這台 Mac 的設定備份（B8）。
///
/// **只寫不讀**：這台的真相在 UserDefaults，iCloud 上那份是備份。重灌或換機
/// 時在設定頁明確挑一份匯入——每次啟動都拿備份回頭套本機，只會多出一條
/// 「拿舊資料蓋新資料」的路徑，而它換來的好處本來就要人工介入。
///
/// 因為沒有自動讀回，**綁機器的鍵也可以收進來**（顯示器怪癖、裝置 UID、
/// 隔離名單）——同一台重灌時那些正是最想要回來的東西。跨機匯入時再靠
/// `BackupPortability` 把它們濾掉。
///
/// 集合一律存成**排序過的陣列**而不是 `Set`：`Set` 的編碼順序不保證，
/// 內容沒變也會被判成「變了」，於是每一拍都重寫一次檔。
public struct DeviceBackup: VersionedSnapshot, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var savedAt: Date
    /// 給人看的機器名（檔名也用它）。
    public var deviceName: String
    /// 這台的長期身分。**不用硬體 UUID**——那要 IOKit，也是個追得到人的
    /// 識別碼，而這裡只需要「同一台機器認得出自己上次寫的那份」。
    /// 直接沿用既有的 per-install peerID。
    public var deviceID: String

    // MARK: 場景

    public var scenes: [ControlScene]

    // MARK: 音訊

    public var deviceEQ: [String: EQSettings]
    public var deviceBalance: [String: Double]
    public var deviceEffects: [String: [AUEffectEntry]]
    public var appAudio: AppAudioSettings
    public var excludedApps: [String]
    public var excludedDevices: [String]
    public var softwareVolumeDevices: [String]
    public var outputPriority: [String]
    public var hiddenAudioDevices: [String]
    public var audioBridgeDisabled: [String]
    public var virtualTargetUID: String?
    public var effectQuarantine: [String]
    public var audioTapsEnabled: Bool

    // MARK: 顯示器

    public var forceSoftwareDimming: [String]
    public var subZeroDimming: [String]
    public var disableDDCRead: [String]
    public var autoBrightnessEnabled: Bool
    public var ambientCurve: AmbientCurve
    public var ambientDisplayOffsets: [String: Double]
    public var ambientDeviceOffset: Double
    public var ambientExcludedDisplays: [String]

    // MARK: 整機偏好

    public var keepAwakePreventsSystemSleep: Bool
    public var keepAwakeDisplayUUID: String?
    public var keepAwakeAppBundleID: String?
    public var mediaKeyCaptureEnabled: Bool
    public var syncBrightnessEnabled: Bool
    public var syncVolumeEnabled: Bool
    public var advisorEngineID: String
    public var advisorModelIDs: [String: String]
    public var advisorDisabledEngines: [String]
    public var advisorCustomPaths: [String: String]
    public var automationServerEnabled: Bool
    public var automationServerPort: UInt16
    public var focusLastDuration: Double
    public var focusNotifyOnEnd: Bool
    public var cloudBackupEnabled: Bool

    public init(
        version: Int = DeviceBackup.currentVersion,
        savedAt: Date,
        deviceName: String,
        deviceID: String,
        scenes: [ControlScene] = [],
        deviceEQ: [String: EQSettings] = [:],
        deviceBalance: [String: Double] = [:],
        deviceEffects: [String: [AUEffectEntry]] = [:],
        appAudio: AppAudioSettings = AppAudioSettings(),
        excludedApps: [String] = [],
        excludedDevices: [String] = [],
        softwareVolumeDevices: [String] = [],
        outputPriority: [String] = [],
        hiddenAudioDevices: [String] = [],
        audioBridgeDisabled: [String] = [],
        virtualTargetUID: String? = nil,
        effectQuarantine: [String] = [],
        audioTapsEnabled: Bool = false,
        forceSoftwareDimming: [String] = [],
        subZeroDimming: [String] = [],
        disableDDCRead: [String] = [],
        autoBrightnessEnabled: Bool = false,
        ambientCurve: AmbientCurve = AmbientCurve(),
        ambientDisplayOffsets: [String: Double] = [:],
        ambientDeviceOffset: Double = 0,
        ambientExcludedDisplays: [String] = [],
        keepAwakePreventsSystemSleep: Bool = false,
        keepAwakeDisplayUUID: String? = nil,
        keepAwakeAppBundleID: String? = nil,
        mediaKeyCaptureEnabled: Bool = false,
        syncBrightnessEnabled: Bool = true,
        syncVolumeEnabled: Bool = true,
        advisorEngineID: String = "claude",
        advisorModelIDs: [String: String] = [:],
        advisorDisabledEngines: [String] = [],
        advisorCustomPaths: [String: String] = [:],
        automationServerEnabled: Bool = false,
        automationServerPort: UInt16 = 55780,
        focusLastDuration: Double = 1_500,
        focusNotifyOnEnd: Bool = false,
        cloudBackupEnabled: Bool = false
    ) {
        self.version = version
        self.savedAt = savedAt
        self.deviceName = deviceName
        self.deviceID = deviceID
        self.scenes = scenes
        self.deviceEQ = deviceEQ
        self.deviceBalance = deviceBalance
        self.deviceEffects = deviceEffects
        self.appAudio = appAudio
        self.excludedApps = excludedApps.sorted()
        self.excludedDevices = excludedDevices.sorted()
        self.softwareVolumeDevices = softwareVolumeDevices.sorted()
        self.outputPriority = outputPriority
        self.hiddenAudioDevices = hiddenAudioDevices.sorted()
        self.audioBridgeDisabled = audioBridgeDisabled.sorted()
        self.virtualTargetUID = virtualTargetUID
        self.effectQuarantine = effectQuarantine.sorted()
        self.audioTapsEnabled = audioTapsEnabled
        self.forceSoftwareDimming = forceSoftwareDimming.sorted()
        self.subZeroDimming = subZeroDimming.sorted()
        self.disableDDCRead = disableDDCRead.sorted()
        self.autoBrightnessEnabled = autoBrightnessEnabled
        self.ambientCurve = ambientCurve
        self.ambientDisplayOffsets = ambientDisplayOffsets
        self.ambientDeviceOffset = ambientDeviceOffset
        self.ambientExcludedDisplays = ambientExcludedDisplays.sorted()
        self.keepAwakePreventsSystemSleep = keepAwakePreventsSystemSleep
        self.keepAwakeDisplayUUID = keepAwakeDisplayUUID
        self.keepAwakeAppBundleID = keepAwakeAppBundleID
        self.mediaKeyCaptureEnabled = mediaKeyCaptureEnabled
        self.syncBrightnessEnabled = syncBrightnessEnabled
        self.syncVolumeEnabled = syncVolumeEnabled
        self.advisorEngineID = advisorEngineID
        self.advisorModelIDs = advisorModelIDs
        self.advisorDisabledEngines = advisorDisabledEngines.sorted()
        self.advisorCustomPaths = advisorCustomPaths
        self.automationServerEnabled = automationServerEnabled
        self.automationServerPort = automationServerPort
        self.focusLastDuration = focusLastDuration
        self.focusNotifyOnEnd = focusNotifyOnEnd
        self.cloudBackupEnabled = cloudBackupEnabled
    }

    // MARK: - 解碼

    /// 手寫而不是讓編譯器合成：**合成的版本不會用屬性預設值**，欄位缺一個
    /// 就整份解不開。舊版寫下的檔案沒有後來才加的欄位——那不是損壞，
    /// 是正常的，而且這正是「換一台新機器、Chorus 版本不同」的常態。
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func list(_ key: CodingKeys) throws -> [String] {
            try c.decodeIfPresent([String].self, forKey: key) ?? []
        }
        version = try c.decode(Int.self, forKey: .version)
        savedAt = try c.decode(Date.self, forKey: .savedAt)
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName) ?? "Mac"
        deviceID = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? ""
        scenes = try c.decodeIfPresent([ControlScene].self, forKey: .scenes) ?? []
        deviceEQ = try c.decodeIfPresent([String: EQSettings].self, forKey: .deviceEQ) ?? [:]
        deviceBalance = try c.decodeIfPresent([String: Double].self, forKey: .deviceBalance) ?? [:]
        deviceEffects = try c.decodeIfPresent([String: [AUEffectEntry]].self, forKey: .deviceEffects) ?? [:]
        appAudio = try c.decodeIfPresent(AppAudioSettings.self, forKey: .appAudio) ?? AppAudioSettings()
        excludedApps = try list(.excludedApps)
        excludedDevices = try list(.excludedDevices)
        softwareVolumeDevices = try list(.softwareVolumeDevices)
        outputPriority = try list(.outputPriority)
        hiddenAudioDevices = try list(.hiddenAudioDevices)
        audioBridgeDisabled = try list(.audioBridgeDisabled)
        virtualTargetUID = try c.decodeIfPresent(String.self, forKey: .virtualTargetUID)
        effectQuarantine = try list(.effectQuarantine)
        audioTapsEnabled = try c.decodeIfPresent(Bool.self, forKey: .audioTapsEnabled) ?? false
        forceSoftwareDimming = try list(.forceSoftwareDimming)
        subZeroDimming = try list(.subZeroDimming)
        disableDDCRead = try list(.disableDDCRead)
        autoBrightnessEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoBrightnessEnabled) ?? false
        ambientCurve = try c.decodeIfPresent(AmbientCurve.self, forKey: .ambientCurve) ?? AmbientCurve()
        ambientDisplayOffsets = try c.decodeIfPresent([String: Double].self, forKey: .ambientDisplayOffsets) ?? [:]
        ambientDeviceOffset = try c.decodeIfPresent(Double.self, forKey: .ambientDeviceOffset) ?? 0
        ambientExcludedDisplays = try list(.ambientExcludedDisplays)
        keepAwakePreventsSystemSleep = try c.decodeIfPresent(
            Bool.self, forKey: .keepAwakePreventsSystemSleep) ?? false
        keepAwakeDisplayUUID = try c.decodeIfPresent(String.self, forKey: .keepAwakeDisplayUUID)
        keepAwakeAppBundleID = try c.decodeIfPresent(String.self, forKey: .keepAwakeAppBundleID)
        mediaKeyCaptureEnabled = try c.decodeIfPresent(Bool.self, forKey: .mediaKeyCaptureEnabled) ?? false
        syncBrightnessEnabled = try c.decodeIfPresent(Bool.self, forKey: .syncBrightnessEnabled) ?? true
        syncVolumeEnabled = try c.decodeIfPresent(Bool.self, forKey: .syncVolumeEnabled) ?? true
        advisorEngineID = try c.decodeIfPresent(String.self, forKey: .advisorEngineID) ?? "claude"
        advisorModelIDs = try c.decodeIfPresent([String: String].self, forKey: .advisorModelIDs) ?? [:]
        advisorDisabledEngines = try list(.advisorDisabledEngines)
        advisorCustomPaths = try c.decodeIfPresent([String: String].self, forKey: .advisorCustomPaths) ?? [:]
        automationServerEnabled = try c.decodeIfPresent(Bool.self, forKey: .automationServerEnabled) ?? false
        automationServerPort = try c.decodeIfPresent(UInt16.self, forKey: .automationServerPort) ?? 55780
        focusLastDuration = try c.decodeIfPresent(Double.self, forKey: .focusLastDuration) ?? 1_500
        focusNotifyOnEnd = try c.decodeIfPresent(Bool.self, forKey: .focusNotifyOnEnd) ?? false
        cloudBackupEnabled = try c.decodeIfPresent(Bool.self, forKey: .cloudBackupEnabled) ?? false
    }

    /// 內容是否等價——**不看 `savedAt`**。連時間戳一起比的話每次都不相等，
    /// 於是每一拍都重寫一次檔（Foldwall 踩過的同一個坑）。
    public func hasSameContent(as other: DeviceBackup) -> Bool {
        var a = self, b = other
        a.savedAt = .distantPast
        b.savedAt = .distantPast
        return a == b
    }
}

/// 跨機匯入時哪些欄位跟著走、哪些留在本機。
///
/// **判準只有一條：換到另一台 Mac，這個值還是同一件事嗎？**
///
/// 這兩份名單是給測試用的登錄表——`portableMerged` 是逐欄位手寫的，
/// 而測試會拿兩份完全不同的備份跑一次合併，用反射逐欄位對照這裡。
/// 新增欄位沒登錄、或 `portableMerged` 漏寫一行，測試就紅。
public enum BackupPortability {
    /// 跨機匯入時**保留本機的值**。
    public static let machineBound: Set<String> = [
        // 顯示器 UUID 為鍵的硬體怪癖與環境光設定：另一台的顯示器不是這幾台
        "forceSoftwareDimming", "subZeroDimming", "disableDDCRead",
        "ambientDisplayOffsets", "ambientExcludedDisplays",
        // 裝置 UID 為鍵：同理
        "hiddenAudioDevices", "audioBridgeDisabled", "excludedDevices",
        "softwareVolumeDevices", "outputPriority", "virtualTargetUID",
        // 綁定的是這台的螢幕／這台裝了什麼 App
        "keepAwakeDisplayUUID", "keepAwakeAppBundleID",
        // 崩潰紀錄綁機：另一台的那個外掛可能沒問題
        "effectQuarantine",
        // 路徑綁機
        "advisorCustomPaths",
        // **權限與資料出境一律各台自己開**（PLAN §8-6）。把它們搬過去，
        // 等於在另一台悄悄開了系統音訊錄製、本機 HTTP 介面或雲端備份
        "audioTapsEnabled", "automationServerEnabled", "cloudBackupEnabled",
    ]

    /// 跨機匯入時**採用備份的值**。
    public static let portable: Set<String> = [
        "scenes",
        "deviceEQ", "deviceBalance", "deviceEffects", "appAudio", "excludedApps",
        "autoBrightnessEnabled", "ambientCurve", "ambientDeviceOffset",
        "keepAwakePreventsSystemSleep", "mediaKeyCaptureEnabled",
        "syncBrightnessEnabled", "syncVolumeEnabled",
        "advisorEngineID", "advisorModelIDs", "advisorDisabledEngines",
        "automationServerPort", "focusLastDuration", "focusNotifyOnEnd",
    ]

    /// 身分欄位：不參與可攜性判斷（匯入後一律是**這台**的身分）。
    public static let identity: Set<String> = ["version", "savedAt", "deviceName", "deviceID"]
}

public extension DeviceBackup {
    /// 跨機匯入：可攜欄位採用這一份，綁機與權限欄位保留 `local` 的。
    ///
    /// 身分欄位也保留 `local` 的——匯入別台的設定之後，這台**還是這台**，
    /// 下一次備份不該把自己寫進對方的檔名底下。
    func portableMerged(onto local: DeviceBackup) -> DeviceBackup {
        var result = self
        result.version = local.version
        result.savedAt = local.savedAt
        result.deviceName = local.deviceName
        result.deviceID = local.deviceID

        result.forceSoftwareDimming = local.forceSoftwareDimming
        result.subZeroDimming = local.subZeroDimming
        result.disableDDCRead = local.disableDDCRead
        result.ambientDisplayOffsets = local.ambientDisplayOffsets
        result.ambientExcludedDisplays = local.ambientExcludedDisplays
        result.hiddenAudioDevices = local.hiddenAudioDevices
        result.audioBridgeDisabled = local.audioBridgeDisabled
        result.excludedDevices = local.excludedDevices
        result.softwareVolumeDevices = local.softwareVolumeDevices
        result.outputPriority = local.outputPriority
        result.virtualTargetUID = local.virtualTargetUID
        result.keepAwakeDisplayUUID = local.keepAwakeDisplayUUID
        result.keepAwakeAppBundleID = local.keepAwakeAppBundleID
        result.effectQuarantine = local.effectQuarantine
        result.advisorCustomPaths = local.advisorCustomPaths
        result.audioTapsEnabled = local.audioTapsEnabled
        result.automationServerEnabled = local.automationServerEnabled
        result.cloudBackupEnabled = local.cloudBackupEnabled

        // per-app 的路由指向**本機的**裝置 UID，跨機是空殼——設定看起來
        // 搬過去了，實際上那個裝置不在這台上。其餘欄位（EQ、效果鏈、
        // 增益、靜音）照搬。
        result.appAudio = Self.clearingRoutes(appAudio)
        return result
    }

    private static func clearingRoutes(_ settings: AppAudioSettings) -> AppAudioSettings {
        var cleaned = AppAudioSettings()
        for bundleID in settings.adjustedBundleIDs {
            var entry = settings[bundleID]
            entry.outputDeviceUID = nil
            cleaned[bundleID] = entry
        }
        return cleaned
    }
}
