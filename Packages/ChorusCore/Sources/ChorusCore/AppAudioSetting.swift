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
    /// App 層等化（B6-8 擴充：與裝置層是**不同責任的兩次**，
    /// DESIGN-20260830-au-hosting §1.2）。`nil` ＝ 沒有。
    public var eq: EQSettings?
    /// App 層 AU 效果鏈（B6-8）。順序即處理順序；空陣列＝沒有。
    public var effects: [AUEffectEntry]

    public init(
        gain: Float = 1, muted: Bool = false, outputDeviceUID: String? = nil,
        eq: EQSettings? = nil, effects: [AUEffectEntry] = []
    ) {
        self.gain = AppAudioSetting.clampGain(gain)
        self.muted = muted
        self.outputDeviceUID = outputDeviceUID
        self.eq = eq
        self.effects = effects
    }

    /// 舊存檔沒有 eq／effects 欄位——缺欄位就是「沒有」，不是解碼失敗。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        gain = AppAudioSetting.clampGain(try container.decode(Float.self, forKey: .gain))
        muted = try container.decode(Bool.self, forKey: .muted)
        outputDeviceUID = try container.decodeIfPresent(String.self, forKey: .outputDeviceUID)
        eq = try container.decodeIfPresent(EQSettings.self, forKey: .eq)
        effects = try container.decodeIfPresent([AUEffectEntry].self, forKey: .effects) ?? []
    }

    public static let gainRange: ClosedRange<Float> = 0...GainRamp.maxGain

    public static func clampGain(_ value: Float) -> Float {
        min(max(value, gainRange.lowerBound), gainRange.upperBound)
    }

    /// 沒有任何值得**保存**的東西（儲存判準）。注意與 `needsTap` 不同：
    /// 「EQ 存著但關掉」要保留設定（使用者調了十分鐘的 preset 不能因為
    /// 暫時關掉就蒸發——與裝置版 EQ 同一態度），但不值得為它建 tap。
    public var isNeutral: Bool {
        gain == 1 && !muted && outputDeviceUID == nil
            && eq == nil && effects.isEmpty
    }

    /// **「要不要建 tap」的判準**（DESIGN §2.3 規則 2：沒被調整的 App
    /// 一個 tap 都不建）。eq 要**生效**、效果鏈要有**啟用中的格**才算。
    public var needsTap: Bool {
        gain != 1 || muted || outputDeviceUID != nil
            || eq?.isActive == true || effects.contains(where: \.enabled)
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

    /// 有任何保存內容的 bundle（排序後，讓 UI 與 state dump 穩定）。
    /// UI 的「已調整」清單用它——EQ 關著的 App 也要找得到地方調回來。
    public var adjustedBundleIDs: [String] {
        entries.keys.sorted()
    }

    /// 需要建 tap 的 bundle（`needsTap`，見 AppAudioSetting 的兩個判準）。
    /// TapEngine 的對帳用它——存了關著的 EQ 不代表要接管音訊。
    public var bundleIDsNeedingTap: [String] {
        entries.filter { $0.value.needsTap }.keys.sorted()
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func reset(bundleID: String) {
        entries.removeValue(forKey: bundleID)
    }
}
