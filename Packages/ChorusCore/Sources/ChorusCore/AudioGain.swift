/// Realtime 端會逐樣本呼叫的增益數學（B6-2）。
///
/// 放在 ChorusCore 是為了**讓 realtime 走的就是被測到的那份程式碼**：
/// 若把 DSP 寫在 render block 裡、另外寫一份「等價」的純函式去測，
/// 兩份遲早會漂移，而漂移的那一份剛好是沒人聽得出來哪裡不對的那一份。
///
/// 因此這裡的每個函式都必須是 **realtime-safe**：不配置、不上鎖、
/// 不碰 ObjC、沒有 ARC（全 struct／static，只做浮點運算）。
/// `@inlinable` 是必要的——跨模組呼叫若不能內聯，realtime 端就會多一次
/// 函式呼叫與潛在的 retain/release（PLAN §8-2）。
public enum SoftClip: Sendable {
    /// 線性區的上限（**boost 用**）。低於此值原樣通過。
    /// 0.7 是給 >1x 增益的緩衝——大幅 boost 需要提早、平緩地收。
    public static let threshold: Float = 0.7

    /// 線性區的上限（**純保護用**）。增益 ≤ 1、只掛 EQ 時，素材頂多因
    /// 頻段間疊加微幅過頂（實測 preset 約 +0.04 dB）——這時 0.7 的膝點
    /// 等於對貼著滿刻度的現代母帶持續失真（場次 D14 實聽：不定時沙沙，
    /// 播放器音量降一半就消失）。保護膝點只在真正逼近天花板時介入。
    public static let protectThreshold: Float = 0.95

    /// 曲線碰到天花板 ±1 的輸入振幅。超過這裡就是真的限幅了
    /// （4x 增益打進本來就接近滿刻度的訊號，任何 limiter 都只能這樣）。
    public static let ceilingInput: Float = threshold + 3 * (1 - threshold) // 1.6

    /// Soft knee：|x| ≤ t 原樣通過，超過的部分壓進 (t, 1]。
    ///
    /// 公式（自導，非搬碼）：
    ///
    ///     y = t + (1 - t) · S((|x| - t) / (1 - t))
    ///
    /// `S` 見 `saturate`。這個包裝的重點是**接點**：`S(0) = 0`、`S'(0) = 1`，
    /// 代進去剛好讓 y(t) = t 且 y'(t) = 1——曲線與線性區在 threshold 上
    /// 值與斜率都連續。硬 knee 在接點斜率跳變，那個轉折聽得出來。
    @inlinable
    @inline(__always)
    public static func apply(_ sample: Float, threshold t: Float = threshold) -> Float {
        let magnitude = abs(sample)
        guard magnitude > t else { return sample }
        let knee = 1 - t
        let compressed = t + knee * saturate((magnitude - t) / knee)
        return sample < 0 ? -compressed : compressed
    }

    /// 三次有理飽和函數 `S(x) = x(27 + x²) / (27 + 9x²)`，超過 ±3 夾住。
    ///
    /// 不呼叫 libm 的 `tanhf`：realtime 執行緒上外部函式的行為
    /// （lazy binding、errno 副作用）不在我們掌握中，而這裡要的只是幾個
    /// 幾何性質。這個式子全部給滿：
    ///
    /// - `S(0) = 0`、`S'(0) = 1` → 與線性區平滑接上（見 `apply`）。
    /// - 奇對稱 → 不引入直流偏移。
    /// - `S(x) - 1 = (x - 3)³ / (27 + 9x²)` → **在 x = 3 剛好等於 1，
    ///   而且斜率為 0**：曲線是「貼著」天花板停下，不是撞上去。
    ///   tanh 只會漸近 1、永遠到不了，反而需要另外處理殘餘溢出。
    ///
    /// 注意它不是 tanh 的逼近——x > 3 之後原式會發散，靠 clamp 收尾；
    /// 定義域內（我們只餵 0…約 4.7）行為完全由上面三條決定。
    @inlinable
    @inline(__always)
    public static func saturate(_ value: Float) -> Float {
        let squared = value * value
        let curve = value * (27 + squared) / (27 + 9 * squared)
        return min(max(curve, -1), 1)
    }
}

/// 增益的線性斜坡（B6-2）。
///
/// 存在的理由：增益突變＝樣本波形上的階躍＝**爆音**。使用者拖滑桿時
/// 每次移動都是一次突變，靜音更是從 1 直接掉到 0。
/// FineTune 為此有一整個 Crossfade 模組；我們只需要最小解——
/// 每個 callback 往目標值逼近固定的量，~10 ms 內到位。
///
/// 斜率刻意用**固定值**（不是「距離除以剩餘時間」）：後者每個 callback
/// 重算會變成指數逼近，永遠到不了目標，而 realtime 端不該有「幾乎相等」
/// 這種需要 epsilon 判斷的狀態。固定斜率會真的走到目標並停住。
public enum GainRamp: Sendable {
    /// 最大增益（0–4x，PLAN B6-2）。斜率以「全程 10 ms」定義。
    public static let maxGain: Float = 4
    /// 48 kHz 下的 10 ms。tap 格式固定 48 kHz（DESIGN §1 實測），
    /// 但即使取樣率不同，這個斜率的量級也還在「不爆音又跟得上手」的區間。
    public static let framesToFullRange: Float = 480

    @inlinable
    public static var slopePerFrame: Float { maxGain / framesToFullRange }

    /// 這個 callback 結束時的增益值。`frames` 是本次回呼的 frame 數
    /// （不是樣本數——立體聲一次回呼有兩倍樣本，但只走過一次時間）。
    @inlinable
    @inline(__always)
    public static func advance(current: Float, target: Float, frames: Int) -> Float {
        let maxDelta = slopePerFrame * Float(frames)
        let delta = target - current
        if delta > maxDelta { return current + maxDelta }
        if delta < -maxDelta { return current - maxDelta }
        return target
    }
}
