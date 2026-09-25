import Foundation

/// 「音量模式」的決策模型。
///
/// 以前這件事散在三處各判一次：`AudioDeviceModel.forwardVolumeMode`（自動優先序）、
/// `AudioDeviceManager.updateVirtualMirrorMode`（driver 要不要做數位衰減）、
/// 設定頁從 `driver.mirrorMode` 這個布林值反推顯示文字。布林值反推是錯的
/// ——它只能分辨「鏡射／不鏡射」，講不出鏡射到的是 DDC 還是裝置原生音量。
///
/// 這裡把它收成一個決策：**偏好 ＋ 可用性 → 目前生效模式**。三個使用者
/// （driver 設定、滑桿徽章、設定頁文字）讀同一份答案。
public enum VolumeMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// 沿用自動優先序：DDC → 裝置原生 → 數位衰減。
    case auto
    /// 寫進螢幕硬體（DDC/CI VCP 0x62）。
    case ddc
    /// 寫進音訊裝置自己的 CoreAudio 音量。
    case native
    /// 由虛擬輸出 driver 做軟體衰減。
    case digital
}

/// 實際生效的模式。沒有 `auto`——「目前生效」永遠是三條路徑之一。
public enum EffectiveVolumeMode: String, Sendable, Hashable {
    case ddc
    case native
    case digital
}

/// 某個模式為什麼不能用。文案在 App 層（本套件不做本地化）。
public enum VolumeModeUnavailability: String, Sendable, Hashable {
    /// 這個音訊裝置沒有對應到可用 DDC 的螢幕。
    case noDDCDisplay
    /// 有對應螢幕，但寫後驗證確認它不理音量指令（或使用者標記了不支援）。
    case ddcUnresponsive
    /// 裝置沒有 CoreAudio 原生音量（HDMI／DP 常見）。
    case noNativeVolume
    /// 沒有數位衰減路徑（音訊沒有經過 Chorus 的虛擬輸出）。
    case noDigitalPath
}

public enum VolumeModePolicy {
    /// 某個目標裝置目前有哪些路徑走得通。
    public struct Availability: Sendable, Equatable {
        /// 有對應的 DDC 螢幕可寫。
        public var hasDDCBridge: Bool
        /// 該 DDC 橋接目前可信（沒有被寫後驗證判定無回應、也沒被使用者停用）。
        public var ddcResponsive: Bool
        /// 裝置自己有 CoreAudio 音量。
        public var hasNativeVolume: Bool
        /// 虛擬輸出 driver 正在轉送到這個裝置（數位衰減才有著力點）。
        public var hasDigitalPath: Bool

        public init(
            hasDDCBridge: Bool = false,
            ddcResponsive: Bool = true,
            hasNativeVolume: Bool = false,
            hasDigitalPath: Bool = false
        ) {
            self.hasDDCBridge = hasDDCBridge
            self.ddcResponsive = ddcResponsive
            self.hasNativeVolume = hasNativeVolume
            self.hasDigitalPath = hasDigitalPath
        }
    }

    /// 決策結果。
    public struct Resolution: Sendable, Equatable {
        /// 現在真的在用的路徑。UI 顯示「目前生效模式」讀這個。
        public let effective: EffectiveVolumeMode
        /// 使用者選了手動模式但它現在不能用時，記下**原本選的是什麼**。
        /// 偏好本身不會被改寫——能力恢復後要能自己接回去。
        public let degradedFrom: VolumeMode?
        /// 降級原因（`degradedFrom` 為 nil 時也是 nil）。
        public let reason: VolumeModeUnavailability?

        public init(
            effective: EffectiveVolumeMode,
            degradedFrom: VolumeMode? = nil,
            reason: VolumeModeUnavailability? = nil
        ) {
            self.effective = effective
            self.degradedFrom = degradedFrom
            self.reason = reason
        }

        public var isDegraded: Bool { degradedFrom != nil }
    }

    /// 這個模式現在為什麼不能選（可以選時回 nil）。`auto` 永遠可選。
    public static func unavailability(
        of mode: VolumeMode,
        given availability: Availability
    ) -> VolumeModeUnavailability? {
        switch mode {
        case .auto:
            nil
        case .ddc:
            if !availability.hasDDCBridge { .noDDCDisplay }
            else if !availability.ddcResponsive { .ddcUnresponsive }
            else { nil }
        case .native:
            availability.hasNativeVolume ? nil : .noNativeVolume
        case .digital:
            availability.hasDigitalPath ? nil : .noDigitalPath
        }
    }

    public static func isAvailable(_ mode: VolumeMode, given availability: Availability) -> Bool {
        unavailability(of: mode, given: availability) == nil
    }

    /// 自動模式的優先序：DDC → 原生 → 數位。
    ///
    /// 順序不是隨便排的——有硬體音量卻走數位衰減是純粹的損失（位深＋額外延遲），
    /// 所以能寫硬體就先寫硬體。都走不通時仍回 `.digital`：那是唯一不需要
    /// 任何裝置能力的路徑，讓滑桿至少還有作用。
    public static func automaticChoice(given availability: Availability) -> EffectiveVolumeMode {
        if availability.hasDDCBridge, availability.ddcResponsive { return .ddc }
        if availability.hasNativeVolume { return .native }
        return .digital
    }

    /// 偏好 ＋ 可用性 → 目前生效模式。
    ///
    /// 手動模式在運作中失效（螢幕被判定不理 DDC、裝置拔掉換成另一個）時
    /// **保留偏好**、以自動模式暫時接手並標示降級原因；能力恢復後下一次
    /// resolve 就自己接回去，不需要使用者再選一次。
    public static func resolve(preference: VolumeMode, availability: Availability) -> Resolution {
        if preference == .auto {
            return Resolution(effective: automaticChoice(given: availability))
        }
        if let reason = unavailability(of: preference, given: availability) {
            let fallback = automaticChoice(given: availability)
            // 退路剛好就是使用者選的那條時不算降級。`.digital` 會走到這裡：
            // 它是自動優先序的保底，所以「數位路徑不可用」的同時退路仍是數位。
            // 標成降級的話，UI 會對著正在運作的模式說它無法使用。
            if fallback.rawValue == preference.rawValue {
                return Resolution(effective: fallback)
            }
            return Resolution(effective: fallback, degradedFrom: preference, reason: reason)
        }
        let effective: EffectiveVolumeMode = switch preference {
        case .ddc: .ddc
        case .native: .native
        case .digital: .digital
        case .auto: automaticChoice(given: availability)
        }
        return Resolution(effective: effective)
    }

    /// driver 要不要做整體數位衰減。
    ///
    /// **與生效模式互斥**：DDC／原生模式下 driver 必須放行原樣樣本，否則同一次
    /// 滑桿操作會被套用兩次（硬體一次、數位一次）；數位模式下則必須關掉硬體
    /// 鏡射，否則手動選了「數位衰減」還是會去改螢幕的硬體音量。
    public static func driverAppliesVolume(for effective: EffectiveVolumeMode) -> Bool {
        effective == .digital
    }

    /// 生效模式要不要把音量鏡射到目標裝置的硬體。
    public static func mirrorsToHardware(for effective: EffectiveVolumeMode) -> Bool {
        effective != .digital
    }
}
