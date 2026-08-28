import Foundation

/// 一段可編輯的 EQ。
public struct EQBand: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: BiquadKind
    /// 中心／轉角頻率（Hz）。
    public var frequency: Double
    public var gainDB: Double
    public var q: Double
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        kind: BiquadKind = .peaking,
        frequency: Double,
        gainDB: Double = 0,
        q: Double = 1,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.kind = kind
        self.frequency = frequency
        self.gainDB = gainDB
        self.q = q
        self.isEnabled = isEnabled
    }

    public static let gainRange: ClosedRange<Double> = -20...20
    public static let qRange: ClosedRange<Double> = 0.1...10

    public var coefficients: BiquadCoefficients {
        coefficients(sampleRate: EQSettings.referenceSampleRate)
    }

    public func coefficients(sampleRate: Double) -> BiquadCoefficients {
        guard isEnabled else { return .identity }
        return .make(
            kind: kind,
            frequency: frequency,
            gainDB: min(max(gainDB, Self.gainRange.lowerBound), Self.gainRange.upperBound),
            q: min(max(q, Self.qRange.lowerBound), Self.qRange.upperBound),
            sampleRate: sampleRate
        )
    }
}

/// 一個輸出裝置的等化設定（B6-5）。
public struct EQSettings: Codable, Sendable, Equatable {
    /// tap 的格式固定 48 kHz（DESIGN §1 實測）。係數以它計算；
    /// 真的遇到別的取樣率時 render 端會拿實際值重算。
    public static let referenceSampleRate: Double = 48_000
    /// realtime 端預先配置的段數上限。AutoEq 的檔案通常 10 段，
    /// 少數到 15——16 有餘裕，而且它決定了預配置的狀態陣列大小。
    public static let maxBands = 16

    public var isEnabled: Bool
    /// 前置增益（dB，恆為 0 或負值）。
    public var preampDB: Double
    /// 自動算 preamp。手動編輯時預設開著——正增益不配 negative preamp
    /// 就是保證削波，而使用者不會想自己算那個數字。
    /// 匯入 AutoEq 時關掉，改用檔案給的值。
    public var usesAutomaticPreamp: Bool
    public var bands: [EQBand]
    /// 這組設定的來源說明（例如「AutoEq · Sennheiser HD 600」），
    /// 讓使用者知道畫面上這串數字是哪來的。
    public var sourceName: String?

    public init(
        isEnabled: Bool = false,
        preampDB: Double = 0,
        usesAutomaticPreamp: Bool = true,
        bands: [EQBand] = [],
        sourceName: String? = nil
    ) {
        self.isEnabled = isEnabled
        self.preampDB = preampDB
        self.usesAutomaticPreamp = usesAutomaticPreamp
        self.bands = bands
        self.sourceName = sourceName
    }

    /// 手動模式的預設 10 段（ISO 八度中心頻率，兩端用 shelf）。
    public static func tenBandDefault() -> EQSettings {
        let frequencies: [Double] = [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
        let bands = frequencies.enumerated().map { index, frequency in
            EQBand(
                kind: index == 0 ? .lowShelf : (index == frequencies.count - 1 ? .highShelf : .peaking),
                frequency: frequency,
                q: 1
            )
        }
        return EQSettings(isEnabled: true, bands: bands, sourceName: "手動 10 段")
    }

    /// **實際會生效嗎**。開關開著但每一段都是 0 dB 等於沒有 EQ——
    /// 這種情況不該建 tap（DESIGN §2.3 規則 2 的同一條理由）。
    public var isActive: Bool {
        isEnabled && bands.contains { $0.isEnabled && $0.gainDB != 0 }
    }

    /// 真正送進 realtime 的 preamp。
    ///
    /// 自動模式：**負的最大正增益**。任何一段推高 6 dB，整體就先降 6 dB
    /// ——這正是 AutoEq 在每個 `ParametricEQ.txt` 開頭放 `Preamp:` 的
    /// 理由（PLAN B6-5：必套 negative preamp 防 clipping）。
    public var effectivePreampDB: Double {
        guard usesAutomaticPreamp else { return min(preampDB, 0) }
        let peak = bands.filter(\.isEnabled).map(\.gainDB).max() ?? 0
        return min(-peak, 0)
    }

    /// 線性增益（realtime 端乘的那個數）。
    public var preampGain: Float {
        Float(pow(10, effectivePreampDB / 20))
    }

    public func coefficients(sampleRate: Double = referenceSampleRate) -> [BiquadCoefficients] {
        bands.prefix(Self.maxBands).map { $0.coefficients(sampleRate: sampleRate) }
    }

    /// 整條 cascade（含 preamp）在某個頻率上的響應。UI 畫曲線、
    /// 單元測試對答案都用它。
    public func magnitudeDB(at frequency: Double, sampleRate: Double = referenceSampleRate) -> Double {
        coefficients(sampleRate: sampleRate)
            .reduce(effectivePreampDB) { $0 + $1.magnitudeDB(at: frequency, sampleRate: sampleRate) }
    }
}
