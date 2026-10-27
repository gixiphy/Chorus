/// 來電接手（call-handoff）純邏輯：名義取樣率、語音頻段記憶、hold 決策與播放歸屬。
/// HAL／媒體鍵都在邊界之外——引擎與測試只透過這些型別傳遞。

/// 輸出裝置的名義取樣率。只在擁有它的邊界（CoreAudioTapSession）讀一次 HAL，
/// 之後以這個型別傳遞——引擎與測試都不碰 CoreAudio。
public struct NominalSampleRate: Sendable, Hashable {
    public let hertz: Double

    /// 非有限值或 ≤ 0 → nil。
    public init?(hertz: Double) {
        guard hertz.isFinite, hertz > 0 else { return nil }
        self.hertz = hertz
    }

    /// 藍牙通話（HFP）語音頻段：恰好 8000、16000、24000 Hz。
    public var isTelephonyBand: Bool {
        hertz == 8000 || hertz == 16000 || hertz == 24000
    }
}

/// 每個輸出 UID「最後一次觀察到語音頻段」的時間。之後回到 48000 不清除。
public struct TelephonyRateMemory<Instant: InstantProtocol>: Sendable where Instant.Duration == Duration {
    public static var window: Duration { .seconds(60) }

    private var lastTelephony: [String: Instant] = [:]

    public init() {}

    public mutating func record(_ rate: NominalSampleRate, outputUID: String, at now: Instant) {
        guard rate.isTelephonyBand else { return }
        lastTelephony[outputUID] = now
    }

    /// 過去 60 秒內（含 60.000 s）是否觀察過語音頻段。
    public func isRecentTelephony(outputUID: String, at now: Instant) -> Bool {
        guard let seen = lastTelephony[outputUID] else { return false }
        return seen.duration(to: now) <= Self.window
    }

    /// 紀錄到期的時刻（最後一次 + 60 s）；沒有紀錄回 nil。排程解除武裝用。
    public func expiry(outputUID: String) -> Instant? {
        lastTelephony[outputUID]?.advanced(by: Self.window)
    }
}

public enum CallHandoffDecision: Sendable, Equatable {
    case normal
    case enterHold(outputUID: String)
    case stayHeld(outputUID: String)
    case resume(outputUID: String)
    case deferFollow(outputUID: String)
}

public enum CallHandoffPolicy {
    public static func decide(
        heldUID: String?,
        homeUID: String?,
        followsDefault: Bool,
        defaultUID: String?,
        available: Set<String>,
        homeTelephonyRecent: Bool,
        deferralExpired: Bool
    ) -> CallHandoffDecision {
        if let heldUID {
            if available.contains(heldUID) {
                return .resume(outputUID: heldUID)
            }
            return .stayHeld(outputUID: heldUID)
        }
        if let homeUID, !available.contains(homeUID), homeTelephonyRecent {
            return .enterHold(outputUID: homeUID)
        }
        if followsDefault,
           let homeUID,
           available.contains(homeUID),
           homeTelephonyRecent,
           defaultUID != homeUID,
           !deferralExpired {
            return .deferFollow(outputUID: homeUID)
        }
        return .normal
    }
}

public enum PlaybackCommand: Sendable, Equatable {
    case pause
    case play
}

public enum PlaybackCommandOutcome: Sendable, Equatable {
    /// 實作保證指令送到了這個 bundle（不是「送了一個全域按鍵」）。
    case delivered
    case unsupported
    case failed(String)
}

public enum HandoffPauseState: Sendable, Equatable {
    /// 剛進 hold，等 pauseDue。
    case pending
    /// 播放控制無法確定送到這個 bundle：不送，回來也不播。
    case notAddressable
    /// 判斷時目標沒在發聲：不送，回來也不播。
    case userAlreadyPaused
    /// 已送達，等 verifyDue。
    case requested
    /// 已送達且驗證時已不發聲 → 可歸屬為 Chorus 暫停的。
    case confirmed
    /// 送出失敗，或驗證時仍在發聲。
    case failed
}

public enum HandoffPlaybackPolicy {
    /// pending 到期時呼叫。nil＝送暫停；非 nil＝不送，直接進入該狀態。
    public static func pauseGate(canAddress: Bool, targetAudible: Bool) -> HandoffPauseState? {
        if !canAddress { return .notAddressable }
        if !targetAudible { return .userAlreadyPaused }
        return nil
    }

    public static func afterPauseSent(_ outcome: PlaybackCommandOutcome) -> HandoffPauseState {
        switch outcome {
        case .delivered: return .requested
        case .unsupported: return .notAddressable
        case .failed: return .failed
        }
    }

    public static func verify(_ state: HandoffPauseState, targetAudible: Bool) -> HandoffPauseState {
        guard state == .requested else { return state }
        return targetAudible ? .failed : .confirmed
    }

    public static func shouldAutoPlay(
        _ state: HandoffPauseState,
        canAddressNow: Bool,
        targetAudible: Bool
    ) -> Bool {
        state == .confirmed && canAddressNow && !targetAudible
    }
}
