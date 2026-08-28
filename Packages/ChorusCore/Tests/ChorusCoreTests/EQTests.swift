import Foundation
import Testing
@testable import ChorusCore

/// 掃頻量測：把正弦餵進**實際的 `BiquadState.process`**（realtime 走的
/// 同一份程式碼），量穩態的增益。前 0.2 秒丟掉等暫態過去。
///
/// 用 RMS 比而不是峰值比。取樣後的正弦峰值取決於取樣點落在相位上的哪裡
/// ——16 kHz 在 48 kHz 下一個週期只有三個點，量到的峰值會比真實振幅低
/// 到 1.25 dB，那是量測誤差不是濾波器誤差。RMS 對相位對齊不敏感。
private func measuredGainDB(
    frequency: Double,
    coefficients: [BiquadCoefficients],
    sampleRate: Double = 48_000
) -> Double {
    var states = [BiquadState](repeating: BiquadState(), count: coefficients.count)
    let settleFrames = Int(sampleRate * 0.2)
    let measureFrames = Int(sampleRate * 0.5)
    var inputEnergy: Double = 0
    var outputEnergy: Double = 0
    let step = 2 * Double.pi * frequency / sampleRate

    for frame in 0..<(settleFrames + measureFrames) {
        let input = Float(sin(step * Double(frame)))
        var sample = input
        for index in states.indices {
            sample = states[index].process(sample, coefficients[index])
        }
        if frame >= settleFrames {
            inputEnergy += Double(input) * Double(input)
            outputEnergy += Double(sample) * Double(sample)
        }
    }
    guard inputEnergy > 0, outputEnergy > 0 else { return -.infinity }
    return 10 * log10(outputEnergy / inputEnergy)
}

@Suite("Biquad")
struct BiquadTests {
    /// PLAN B6-5 的驗收條件：正弦掃頻誤差 < 0.5 dB。
    /// 對的是**理論響應**（`magnitudeDB`），不是「跑起來沒爆炸」。
    @Test("掃頻誤差 < 0.5 dB：實際跑過濾波器的結果與理論響應相符")
    func sweepMatchesTheoreticalResponse() {
        let cases: [(BiquadKind, Double, Double, Double)] = [
            (.peaking, 1000, 6, 1.0),
            (.peaking, 1000, -6, 1.0),
            (.peaking, 100, 9, 2.0),
            (.peaking, 8000, -12, 0.7),
            (.lowShelf, 200, 6, 0.7),
            (.highShelf, 6000, -6, 0.7),
        ]
        let probes: [Double] = [50, 100, 200, 500, 1000, 2000, 4000, 8000, 12000, 16000]
        for (kind, frequency, gain, q) in cases {
            let coefficients = BiquadCoefficients.make(
                kind: kind, frequency: frequency, gainDB: gain, q: q, sampleRate: 48_000
            )
            for probe in probes {
                let measured = measuredGainDB(frequency: probe, coefficients: [coefficients])
                let theoretical = coefficients.magnitudeDB(at: probe, sampleRate: 48_000)
                #expect(
                    abs(measured - theoretical) < 0.5,
                    "\(kind) \(Int(frequency))Hz \(gain)dB @ \(Int(probe))Hz：量到 \(measured)、理論 \(theoretical)"
                )
            }
        }
    }

    @Test("peaking 在中心頻率上就是指定的增益")
    func peakingHitsItsGainAtCenter() {
        for gain in [-12.0, -6, -3, 3, 6, 12] {
            let coefficients = BiquadCoefficients.make(
                kind: .peaking, frequency: 1000, gainDB: gain, q: 1, sampleRate: 48_000
            )
            let measured = measuredGainDB(frequency: 1000, coefficients: [coefficients])
            #expect(abs(measured - gain) < 0.5, "\(gain) dB：量到 \(measured)")
        }
    }

    @Test("peaking 遠離中心頻率時不染色")
    func peakingLeavesDistantFrequenciesAlone() {
        let coefficients = BiquadCoefficients.make(
            kind: .peaking, frequency: 1000, gainDB: 12, q: 4, sampleRate: 48_000
        )
        #expect(abs(measuredGainDB(frequency: 50, coefficients: [coefficients])) < 0.5)
        #expect(abs(measuredGainDB(frequency: 16000, coefficients: [coefficients])) < 0.5)
    }

    @Test("shelf 的兩端：通帶到指定增益、另一端維持 0 dB")
    func shelvesLiftOneEndOnly() {
        let low = BiquadCoefficients.make(
            kind: .lowShelf, frequency: 200, gainDB: 6, q: 0.7, sampleRate: 48_000
        )
        #expect(abs(measuredGainDB(frequency: 30, coefficients: [low]) - 6) < 0.5)
        #expect(abs(measuredGainDB(frequency: 8000, coefficients: [low])) < 0.5)

        let high = BiquadCoefficients.make(
            kind: .highShelf, frequency: 4000, gainDB: -6, q: 0.7, sampleRate: 48_000
        )
        #expect(abs(measuredGainDB(frequency: 16000, coefficients: [high]) + 6) < 0.5)
        #expect(abs(measuredGainDB(frequency: 100, coefficients: [high])) < 0.5)
    }

    @Test("級聯相加：多段疊起來的響應是各段之和")
    func cascadeResponsesAdd() {
        let bands = [
            BiquadCoefficients.make(kind: .peaking, frequency: 200, gainDB: 4, q: 1, sampleRate: 48_000),
            BiquadCoefficients.make(kind: .peaking, frequency: 2000, gainDB: -5, q: 1, sampleRate: 48_000),
            BiquadCoefficients.make(kind: .highShelf, frequency: 8000, gainDB: 3, q: 0.7, sampleRate: 48_000),
        ]
        for probe in [100.0, 200, 1000, 2000, 8000, 15000] {
            let measured = measuredGainDB(frequency: probe, coefficients: bands)
            let theoretical = bands.reduce(0.0) { $0 + $1.magnitudeDB(at: probe, sampleRate: 48_000) }
            #expect(abs(measured - theoretical) < 0.5, "@\(Int(probe))Hz：量到 \(measured)、理論 \(theoretical)")
        }
    }

    @Test("無效參數退回直通，不產生 NaN")
    func invalidParametersFallBackToPassthrough() {
        #expect(BiquadCoefficients.make(
            kind: .peaking, frequency: 30000, gainDB: 6, q: 1, sampleRate: 48_000
        ) == .identity) // Nyquist 以上
        #expect(BiquadCoefficients.make(
            kind: .peaking, frequency: 1000, gainDB: 6, q: 0, sampleRate: 48_000
        ) == .identity) // Q = 0
        #expect(BiquadCoefficients.make(
            kind: .peaking, frequency: -1, gainDB: 6, q: 1, sampleRate: 48_000
        ) == .identity)
    }

    @Test("直通係數真的直通")
    func identityPassesThrough() {
        var state = BiquadState()
        for sample in stride(from: Float(-1), through: 1, by: 0.1) {
            #expect(state.process(sample, .identity) == sample)
        }
    }

    @Test("reset 歸零：換 preset 不會被舊狀態拖出一聲")
    func resetClearsState() {
        let coefficients = BiquadCoefficients.make(
            kind: .peaking, frequency: 1000, gainDB: 12, q: 4, sampleRate: 48_000
        )
        var state = BiquadState()
        for _ in 0..<100 { _ = state.process(1, coefficients) }
        state.reset()
        #expect(state == BiquadState())
    }
}

@Suite("EQ settings")
struct EQSettingsTests {
    @Test("開關開著但全是 0 dB 就不算生效——不該為此建 tap")
    func flatEQIsNotActive() {
        var settings = EQSettings.tenBandDefault()
        #expect(!settings.isActive)
        settings.bands[3].gainDB = 3
        #expect(settings.isActive)
        settings.isEnabled = false
        #expect(!settings.isActive)
    }

    @Test("自動 preamp ＝ 負的最大正增益（PLAN B6-5：必套 negative preamp）")
    func automaticPreampCancelsTheHighestBoost() {
        var settings = EQSettings.tenBandDefault()
        settings.bands[2].gainDB = 6
        settings.bands[5].gainDB = 3
        #expect(settings.effectivePreampDB == -6)
        #expect(abs(Double(settings.preampGain) - pow(10, -6.0 / 20)) < 1e-6)
    }

    @Test("全部是衰減時 preamp 不會變成正的（那是把音量偷偷推上去）")
    func automaticPreampNeverBoosts() {
        var settings = EQSettings.tenBandDefault()
        settings.bands[2].gainDB = -6
        #expect(settings.effectivePreampDB == 0)
    }

    @Test("停用的段不計入 preamp")
    func disabledBandsDoNotAffectPreamp() {
        var settings = EQSettings.tenBandDefault()
        settings.bands[2].gainDB = 9
        settings.bands[2].isEnabled = false
        #expect(settings.effectivePreampDB == 0)
    }

    @Test("手動 preamp 一樣夾在 0 以下")
    func manualPreampIsClampedToAttenuation() {
        var settings = EQSettings.tenBandDefault()
        settings.usesAutomaticPreamp = false
        settings.preampDB = 6
        #expect(settings.effectivePreampDB == 0)
        settings.preampDB = -4.5
        #expect(settings.effectivePreampDB == -4.5)
    }

    @Test("正增益的組合套上 preamp 後整體不超過 0 dB——這就是防削波的定義")
    func preampKeepsTheCurveUnderUnity() {
        var settings = EQSettings.tenBandDefault()
        settings.bands[1].gainDB = 8
        settings.bands[4].gainDB = 5
        for probe in stride(from: 20.0, through: 20000, by: 100) {
            #expect(settings.magnitudeDB(at: probe) < 0.5, "@\(Int(probe))Hz 超出 0 dB")
        }
    }

    @Test("預設 10 段：兩端 shelf、中間 peaking")
    func tenBandDefaultShape() {
        let settings = EQSettings.tenBandDefault()
        #expect(settings.bands.count == 10)
        #expect(settings.bands.first?.kind == .lowShelf)
        #expect(settings.bands.last?.kind == .highShelf)
        #expect(settings.bands[5].kind == .peaking)
    }

    @Test("編碼往返保值")
    func roundTripsThroughCoding() throws {
        var settings = EQSettings.tenBandDefault()
        settings.bands[0].gainDB = -3
        settings.sourceName = "AutoEq · HD 600"
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(EQSettings.self, from: data) == settings)
    }
}

@Suite("AutoEq parser")
struct AutoEqParserTests {
    private let sample = """
    Preamp: -6.8 dB
    Filter 1: ON LSC Fc 105 Hz Gain 5.5 dB Q 0.70
    Filter 2: ON PK Fc 1050 Hz Gain -2.4 dB Q 1.20
    Filter 3: ON HSC Fc 10000 Hz Gain -1.2 dB Q 0.70
    Filter 4: OFF PK Fc 3000 Hz Gain 0.0 dB Q 1.00
    """

    @Test("標準格式：段數、型別、頻率、增益、Q 全部對上")
    func parsesTheStandardFormat() throws {
        let settings = try #require(AutoEqParser.parse(sample, sourceName: "AutoEq · 測試"))
        #expect(settings.bands.count == 4)
        #expect(settings.bands[0].kind == .lowShelf)
        #expect(settings.bands[0].frequency == 105)
        #expect(settings.bands[0].gainDB == 5.5)
        #expect(settings.bands[0].q == 0.70)
        #expect(settings.bands[1].kind == .peaking)
        #expect(settings.bands[2].kind == .highShelf)
        #expect(settings.sourceName == "AutoEq · 測試")
    }

    @Test("OFF 的段留著但停用——刪掉會讓段號與原檔對不上")
    func offFiltersAreKeptButDisabled() throws {
        let settings = try #require(AutoEqParser.parse(sample))
        #expect(settings.bands[3].isEnabled == false)
        #expect(settings.bands.count == 4)
    }

    @Test("**必套檔案給的 negative preamp**——AutoEq 算過整條曲線的峰值")
    func usesThePreampFromTheFile() throws {
        let settings = try #require(AutoEqParser.parse(sample))
        #expect(settings.usesAutomaticPreamp == false)
        #expect(settings.effectivePreampDB == -6.8)
    }

    @Test("沒有 Preamp 行時退回自動計算，而不是不做防護")
    func missingPreampFallsBackToAutomatic() throws {
        let text = "Filter 1: ON PK Fc 1000 Hz Gain 7.0 dB Q 1.00"
        let settings = try #require(AutoEqParser.parse(text))
        #expect(settings.usesAutomaticPreamp)
        #expect(settings.effectivePreampDB == -7)
    }

    @Test("別的工具的 LS／HS 寫法也收")
    func acceptsAlternativeShelfTokens() throws {
        let text = """
        Filter 1: ON LS Fc 100 Hz Gain 3.0 dB Q 0.70
        Filter 2: ON HS Fc 8000 Hz Gain 2.0 dB Q 0.70
        """
        let settings = try #require(AutoEqParser.parse(text))
        #expect(settings.bands.map(\.kind) == [.lowShelf, .highShelf])
    }

    @Test("空白寬鬆：多餘空格與大小寫不影響")
    func toleratesLooseWhitespace() throws {
        let text = "  preamp:  -3.0  dB \n  Filter 1:  ON   PK   Fc  1000  Hz   Gain  2.0  dB   Q  1.00 "
        let settings = try #require(AutoEqParser.parse(text))
        #expect(settings.effectivePreampDB == -3)
        #expect(settings.bands.count == 1)
    }

    @Test("沒有任何有效 filter 就是失敗——不要安靜地變成一組全平的 EQ")
    func rejectsFilterlessInput() {
        #expect(AutoEqParser.parse("Preamp: -6.0 dB") == nil)
        #expect(AutoEqParser.parse("") == nil)
        #expect(AutoEqParser.parse("<html>404</html>") == nil)
    }

    @Test("認不得的型別代號跳過，其餘照收")
    func skipsUnknownFilterTypes() throws {
        let text = """
        Filter 1: ON XYZ Fc 100 Hz Gain 3.0 dB Q 0.70
        Filter 2: ON PK Fc 1000 Hz Gain 2.0 dB Q 1.00
        """
        let settings = try #require(AutoEqParser.parse(text))
        #expect(settings.bands.count == 1)
        #expect(settings.bands[0].frequency == 1000)
    }
}
