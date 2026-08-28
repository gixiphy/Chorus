/// Process tap 的健康判讀（B6-1）。
///
/// 存在的理由是一條實測結論（DESIGN-M12 §1.2）：**缺少系統音訊錄製權限時，
/// 整條 tap API 鏈全部回 `noErr`、IOProc 照常觸發，但每個樣本都是零**——
/// 沒有錯誤碼、沒有對話框。「正在發聲卻連續全零」是唯一可靠的判讀訊號。
///
/// 純狀態機、只吃統計數字——app 端每秒餵一個觀察窗，這裡不碰任何 CoreAudio。
public struct TapHealthMonitor: Sendable, Equatable {
    /// 一個觀察窗（約一秒）的統計。
    public struct Window: Sendable, Equatable {
        /// IOProc 回呼次數（0 = 引擎根本沒在跑）。
        public var callbacks: Int
        /// 含非零樣本的回呼次數。
        public var nonZeroCallbacks: Int
        /// 這個窗內是否有被 tap 的來源**正在發聲**
        /// （`kAudioProcessPropertyIsRunningOutput`）。
        /// 沒發聲時收到全零是正常的，不能當權限證據。
        public var anySourceAudible: Bool

        public init(callbacks: Int, nonZeroCallbacks: Int, anySourceAudible: Bool) {
            self.callbacks = callbacks
            self.nonZeroCallbacks = nonZeroCallbacks
            self.anySourceAudible = anySourceAudible
        }
    }

    public enum Verdict: Sendable, Equatable {
        /// 證據不足（引擎沒跑、或來源都沒在發聲）。
        case undetermined
        /// 看過非零樣本——權限確定有。**latch**：TCC 中途撤銷需要重啟 App
        /// 才會生效，引擎存續期間不再改判。
        case healthy
        /// 連續 N 個「有來源發聲卻全零」的窗——判定權限缺失。
        /// latch 到 `reset()`：偵測到就該收掉 tap 走引導，不會自己好。
        case permissionDenied
    }

    /// 判定權限缺失需要的連續可疑窗數。1 太躁（發聲旗標與樣本有時間差），
    /// 預設 2（約兩秒）。
    public let suspicionThreshold: Int
    private var suspicion = 0
    private var latched: Verdict?

    public init(suspicionThreshold: Int = 2) {
        self.suspicionThreshold = max(1, suspicionThreshold)
    }

    public var verdict: Verdict { latched ?? .undetermined }

    /// 餵一個觀察窗，回傳當前判定。
    @discardableResult
    public mutating func record(_ window: Window) -> Verdict {
        if let latched { return latched }
        if window.nonZeroCallbacks > 0 {
            latched = .healthy
            return .healthy
        }
        guard window.callbacks > 0 else { return .undetermined }
        if window.anySourceAudible {
            suspicion += 1
            if suspicion >= suspicionThreshold {
                latched = .permissionDenied
                return .permissionDenied
            }
        }
        // 沒發聲的全零窗不增加也不清除嫌疑：斷續播放時嫌疑要能跨窗累積
        return .undetermined
    }

    /// 引擎重啟（或使用者到系統設定改了權限後重試）時歸零。
    public mutating func reset() {
        suspicion = 0
        latched = nil
    }
}
