/// 單一 App 的音訊調整（B6-2；路由欄位由 B6-3 填）。
///
/// 以 **bundle id** 為鍵而不是 pid：pid 每次啟動都變，而 macOS 26 的
/// `CATapDescription.bundleIDs` ＋ `processRestoreEnabled` 也正好是以
/// bundle 描述 tap（DESIGN §1.1①）——設定與 tap 用同一個識別，
/// 中間不需要任何對應表。
public struct AppAudioSetting: Codable, Sendable, Equatable {
    /// 0–4x。>1 的部分在 realtime 端過 `SoftClip`。
    public var gain: Float
    public var muted: Bool
    /// 指定輸出裝置的 UID；`nil` ＝ 跟隨系統預設輸出（B6-3）。
    public var outputDeviceUID: String?

    public init(gain: Float = 1, muted: Bool = false, outputDeviceUID: String? = nil) {
        self.gain = AppAudioSetting.clampGain(gain)
        self.muted = muted
        self.outputDeviceUID = outputDeviceUID
    }

    public static let gainRange: ClosedRange<Float> = 0...GainRamp.maxGain

    public static func clampGain(_ value: Float) -> Float {
        min(max(value, gainRange.lowerBound), gainRange.upperBound)
    }

    /// 沒有任何調整。**這是「要不要建 tap」的判準**（DESIGN §2.3 規則 2：
    /// 沒被調整的 App 一個 tap 都不建，完全走原生路徑）。
    public var isNeutral: Bool {
        gain == 1 && !muted && outputDeviceUID == nil
    }

    /// realtime 端要的最終目標增益——靜音就是「目標 0」而不是另一條旁路，
    /// 這樣靜音也會走同一條斜坡，不會有喀噠聲（B6-2 ramp）。
    public var targetGain: Float {
        muted ? 0 : gain
    }
}

/// bundle id → 調整。持久化與 tap 生命週期共用這一份。
public struct AppAudioSettings: Codable, Sendable, Equatable {
    public private(set) var entries: [String: AppAudioSetting]

    public init(entries: [String: AppAudioSetting] = [:]) {
        self.entries = entries.filter { !$0.value.isNeutral }
    }

    public subscript(bundleID: String) -> AppAudioSetting {
        get { entries[bundleID] ?? AppAudioSetting() }
        set {
            // 歸零就從表裡消失，不留一筆「gain=1、muted=false」的空紀錄：
            // `tappedBundles` 直接由 keys 推導，留空紀錄＝留一個沒必要的 tap
            if newValue.isNeutral {
                entries.removeValue(forKey: bundleID)
            } else {
                entries[bundleID] = newValue
            }
        }
    }

    /// 需要 tap 的 bundle（排序後，讓 UI 與 state dump 穩定）。
    public var adjustedBundleIDs: [String] {
        entries.keys.sorted()
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func reset(bundleID: String) {
        entries.removeValue(forKey: bundleID)
    }
}
