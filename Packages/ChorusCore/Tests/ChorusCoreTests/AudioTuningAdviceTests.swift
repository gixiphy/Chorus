import Foundation
import Testing
@testable import ChorusCore

@Suite("Audio tuning advice")
struct AudioTuningAdviceTests {
    private var context: AudioTuningContext {
        AudioTuningContext(
            targetKind: "app", targetName: "Podcast", targetDetail: "（bundle id：com.apple.podcasts）",
            request: "人聲清楚一點",
            bandFrequencies: [31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000],
            availableEffects: [
                .init(key: "aaaa-bbbb-cccc", name: "AUMatrixReverb", manufacturerName: "Apple"),
                .init(key: "dddd-eeee-ffff", name: "AUDelay", manufacturerName: "Apple"),
            ]
        )
    }

    @Test("sanitize：增益夾 ±12、段數不足補 0、多的裁掉")
    func gainsAreClampedAndAligned() {
        let advice = AudioTuningAdvice(
            summary: "s",
            eq: .init(bandsGainDB: [99, -99, 3], reason: "r")
        )
        let cleaned = advice.sanitized(for: context)
        #expect(cleaned.eq?.bandsGainDB.count == 10)
        #expect(cleaned.eq?.bandsGainDB[0] == 12)
        #expect(cleaned.eq?.bandsGainDB[1] == -12)
        #expect(cleaned.eq?.bandsGainDB[2] == 3)
        #expect(cleaned.eq?.bandsGainDB[9] == 0)
    }

    @Test("sanitize：全零 EQ 視同無建議")
    func allZeroEQBecomesNil() {
        let advice = AudioTuningAdvice(
            summary: "s", eq: .init(bandsGainDB: Array(repeating: 0, count: 10), reason: "r")
        )
        #expect(advice.sanitized(for: context).eq == nil)
    }

    @Test("sanitize：效果只留清單裡的 key、去重、名稱以本機目錄為準")
    func effectsAreFilteredAndRenamed() {
        let advice = AudioTuningAdvice(summary: "s", effects: [
            .init(componentKey: "aaaa-bbbb-cccc", name: "模型亂寫的名字", reason: "r1"),
            .init(componentKey: "aaaa-bbbb-cccc", name: "重複", reason: "r2"),
            .init(componentKey: "not-in-catalog", name: "編造的外掛", reason: "r3"),
        ])
        let cleaned = advice.sanitized(for: context)
        #expect(cleaned.effects.count == 1)
        #expect(cleaned.effects[0].name == "AUMatrixReverb") // key 才是身分
    }

    @Test("sanitize：效果建議上限 3 格")
    func effectsAreCapped() {
        var wide = context
        wide.availableEffects = (0..<6).map {
            .init(key: "key-\($0)", name: "FX\($0)", manufacturerName: "T")
        }
        let advice = AudioTuningAdvice(summary: "s", effects: (0..<6).map {
            .init(componentKey: "key-\($0)", name: "FX\($0)", reason: "r")
        })
        #expect(advice.sanitized(for: wide).effects.count == AudioTuningAdvice.maxEffectSuggestions)
    }

    @Test("decode 容錯：effects／warnings 缺欄位是空，不是失敗")
    func decodingToleratesMissingFields() throws {
        let json = #"{"summary":"只調 EQ"}"#
        let advice = try JSONDecoder().decode(AudioTuningAdvice.self, from: Data(json.utf8))
        #expect(advice.effects.isEmpty)
        #expect(advice.warnings.isEmpty)
        #expect(advice.eq == nil)
    }

    @Test("prompt 含關鍵段：目標、需求、頻率、AU 清單、schema")
    func promptCarriesTheContext() {
        let prompt = AudioAdvicePrompt.cliPrompt(context: context)
        #expect(prompt.contains("Podcast"))
        #expect(prompt.contains("人聲清楚一點"))
        #expect(prompt.contains("31.5"))
        #expect(prompt.contains("aaaa-bbbb-cccc"))
        #expect(prompt.contains("componentKey"))
        #expect(prompt.contains("繁體中文"))
    }

    @Test("prompt：沒有可用 AU 時明講 effects 給空陣列")
    func promptIsHonestAboutEmptyCatalog() {
        var empty = context
        empty.availableEffects = []
        #expect(AudioAdvicePrompt.contextDescription(empty).contains("effects 請給空陣列"))
    }

    @Test("codec 泛型：jsonEnvelope 解出 AudioTuningAdvice（與光源版同一條尾巴）")
    func genericCodecDecodesAudioAdvice() throws {
        let payload = #"{"summary":"ok","effects":[],"warnings":[]}"#
        let envelope = try String(
            data: JSONSerialization.data(withJSONObject: ["result": payload]), encoding: .utf8
        )!
        let advice = try AdviceCodec.decode(
            stdout: envelope, codec: .jsonEnvelope, as: AudioTuningAdvice.self
        )
        #expect(advice.summary == "ok")
    }
}
