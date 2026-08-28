import Foundation

/// 一段濾波器的種類。AutoEq 的 `ParametricEQ.txt` 只用到這三種，
/// 手動 10 段模式也一樣夠用（兩端用 shelf、中間全用 peaking）。
public enum BiquadKind: String, Codable, Sendable, CaseIterable {
    case peaking
    case lowShelf
    case highShelf

    public var label: String {
        switch self {
        case .peaking: "峰值"
        case .lowShelf: "低頻棚"
        case .highShelf: "高頻棚"
        }
    }
}

/// 二階 IIR 的係數，**已除以 a0**。
///
/// 公式來自 Robert Bristow-Johnson 的 Audio EQ Cookbook——它是這組轉換的
/// 公開標準參考（W3C 的 Web Audio 規格直接收錄同一組式子），與任何
/// GPL 專案無關（PLAN §8-1）。
public struct BiquadCoefficients: Sendable, Equatable {
    public var b0: Float
    public var b1: Float
    public var b2: Float
    public var a1: Float
    public var a2: Float

    public init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }

    /// 直通。band 停用或參數無效時用它——**不要用「跳過這一段」代替**，
    /// 那會讓後面各段的狀態索引跟著位移。
    public static let identity = BiquadCoefficients(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    public static func make(
        kind: BiquadKind,
        frequency: Double,
        gainDB: Double,
        q: Double,
        sampleRate: Double
    ) -> BiquadCoefficients {
        // Nyquist 以上沒有意義；Q ≤ 0 會讓 alpha 發散
        guard sampleRate > 0, frequency > 0, frequency < sampleRate / 2, q > 0 else {
            return .identity
        }
        let amplitude = pow(10, gainDB / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosOmega = cos(omega)
        let alpha = sin(omega) / (2 * q)

        let b0: Double, b1: Double, b2: Double, a0: Double, a1: Double, a2: Double
        switch kind {
        case .peaking:
            b0 = 1 + alpha * amplitude
            b1 = -2 * cosOmega
            b2 = 1 - alpha * amplitude
            a0 = 1 + alpha / amplitude
            a1 = -2 * cosOmega
            a2 = 1 - alpha / amplitude
        case .lowShelf:
            let shared = 2 * sqrt(amplitude) * alpha
            b0 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosOmega + shared)
            b1 = 2 * amplitude * ((amplitude - 1) - (amplitude + 1) * cosOmega)
            b2 = amplitude * ((amplitude + 1) - (amplitude - 1) * cosOmega - shared)
            a0 = (amplitude + 1) + (amplitude - 1) * cosOmega + shared
            a1 = -2 * ((amplitude - 1) + (amplitude + 1) * cosOmega)
            a2 = (amplitude + 1) + (amplitude - 1) * cosOmega - shared
        case .highShelf:
            let shared = 2 * sqrt(amplitude) * alpha
            b0 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosOmega + shared)
            b1 = -2 * amplitude * ((amplitude - 1) + (amplitude + 1) * cosOmega)
            b2 = amplitude * ((amplitude + 1) + (amplitude - 1) * cosOmega - shared)
            a0 = (amplitude + 1) - (amplitude - 1) * cosOmega + shared
            a1 = 2 * ((amplitude - 1) - (amplitude + 1) * cosOmega)
            a2 = (amplitude + 1) - (amplitude - 1) * cosOmega - shared
        }
        guard a0 != 0 else { return .identity }
        return BiquadCoefficients(
            b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0),
            a1: Float(a1 / a0), a2: Float(a2 / a0)
        )
    }

    /// 這一段在某個頻率上的振幅響應（dB）。單元測試拿它當**理論值**去對
    /// 實際跑過濾波器的掃頻結果；UI 的響應曲線也用同一份。
    public func magnitudeDB(at frequency: Double, sampleRate: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let cos1 = cos(omega), sin1 = sin(omega)
        let cos2 = cos(2 * omega), sin2 = sin(2 * omega)
        let numeratorReal = Double(b0) + Double(b1) * cos1 + Double(b2) * cos2
        let numeratorImaginary = -(Double(b1) * sin1 + Double(b2) * sin2)
        let denominatorReal = 1 + Double(a1) * cos1 + Double(a2) * cos2
        let denominatorImaginary = -(Double(a1) * sin1 + Double(a2) * sin2)
        let numerator = (numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary).squareRoot()
        let denominator = (denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary).squareRoot()
        guard denominator > 0, numerator > 0 else { return -.infinity }
        return 20 * log10(numerator / denominator)
    }
}

/// 一段濾波器的狀態（transposed direct form II）。
///
/// **這是 realtime 執行緒逐樣本呼叫的東西**：`@inlinable` 讓它跨模組也能
/// 內聯，內容只有六次乘加，不配置、不上鎖（PLAN §8-2）。TDF-II 而不是
/// DF-I 的理由是狀態只要兩個變數而不是四個——per-channel × per-band
/// 的狀態陣列要預先配置，少一半就是少一半。
public struct BiquadState: Sendable, Equatable {
    @usableFromInline var z1: Float = 0
    @usableFromInline var z2: Float = 0

    public init() {}

    @inlinable
    @inline(__always)
    public mutating func process(_ input: Float, _ coefficients: BiquadCoefficients) -> Float {
        let output = coefficients.b0 * input + z1
        z1 = coefficients.b1 * input - coefficients.a1 * output + z2
        z2 = coefficients.b2 * input - coefficients.a2 * output
        return output
    }

    /// 換一組係數時歸零。不歸零的話舊狀態會以新係數繼續衰減，
    /// 換 preset 的瞬間會聽到一聲。
    @inlinable
    @inline(__always)
    public mutating func reset() {
        z1 = 0
        z2 = 0
    }
}
