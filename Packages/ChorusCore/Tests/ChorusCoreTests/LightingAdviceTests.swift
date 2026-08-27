import Foundation
import Testing
@testable import ChorusCore

@Suite("Lighting advice")
struct LightingAdviceTests {
    private let context = AdviceContext(
        displays: [
            .init(
                id: "display:builtin",
                name: "內建螢幕",
                backend: "displayServices",
                normalizedPosition: [0.45, 0.7],
                currentOffset: 0.02
            ),
            .init(id: "display:asus", name: "ASUS VS207", backend: "gamma")
        ],
        curve: AmbientCurve(minBrightness: 0.15, maxLux: 800),
        recentLux: LuxStats(minLux: 12, medianLux: 180, maxLux: 420)
    )

    @Test("Sanitize drops suggestions for unknown display IDs")
    func unknownDisplayDropped() {
        let advice = LightingAdvice(offsets: [
            .init(displayID: "display:asus", offset: 0.1, reason: "背景亮"),
            .init(displayID: "display:ghost", offset: 0.1, reason: "不存在")
        ])
        let clean = advice.sanitized(for: context)
        #expect(clean.offsets.map(\.displayID) == ["display:asus"])
    }

    @Test("Sanitize clamps offsets and global parameters into allowed ranges")
    func clamping() {
        let advice = LightingAdvice(
            offsets: [.init(displayID: "display:builtin", offset: 0.9, reason: "太多")],
            maxLux: 999_999,
            minBrightness: -1
        )
        let clean = advice.sanitized(for: context)
        #expect(clean.offsets[0].offset == LightingAdvice.offsetRange.upperBound)
        #expect(clean.maxLux == LightingAdvice.maxLuxRange.upperBound)
        #expect(clean.minBrightness == LightingAdvice.minBrightnessRange.lowerBound)
    }

    @Test("Sanitize keeps only the first suggestion per display")
    func deduplication() {
        let advice = LightingAdvice(offsets: [
            .init(displayID: "display:builtin", offset: 0.05, reason: "第一筆"),
            .init(displayID: "display:builtin", offset: -0.05, reason: "第二筆"),
            .init(displayID: "display:asus", offset: 0.1, reason: "另一台")
        ])
        let clean = advice.sanitized(for: context)
        #expect(clean.offsets.count == 2)
        #expect(clean.offsets[0].offset == 0.05)
        #expect(clean.offsets[0].reason == "第一筆")
    }

    @Test("Sanitize rejects non-finite values")
    func nonFinite() {
        let advice = LightingAdvice(
            offsets: [.init(displayID: "display:builtin", offset: .infinity, reason: "壞值")],
            maxLux: .nan,
            minBrightness: .infinity
        )
        let clean = advice.sanitized(for: context)
        #expect(clean.offsets.isEmpty)
        #expect(clean.maxLux == nil)
        #expect(clean.minBrightness == nil)
    }

    @Test("Sanitize trims text and drops empty warnings")
    func textCleanup() {
        let advice = LightingAdvice(
            offsets: [.init(displayID: "display:asus", offset: 0.1, reason: "  背景亮  ")],
            warnings: ["  掛燈請關自動模式  ", "   ", ""],
            sceneSummary: "  無窗隔間。  "
        )
        let clean = advice.sanitized(for: context)
        #expect(clean.offsets[0].reason == "背景亮")
        #expect(clean.warnings == ["掛燈請關自動模式"])
        #expect(clean.sceneSummary == "無窗隔間。")
    }

    @Test("Codable round-trip preserves advice and context")
    func codableRoundTrip() throws {
        let advice = LightingAdvice(
            offsets: [.init(displayID: "display:builtin", offset: -0.05, reason: "陰影帶")],
            maxLux: 800,
            minBrightness: 0.15,
            warnings: ["反光"],
            sceneSummary: "辦公室"
        )
        let decodedAdvice = try JSONDecoder().decode(
            LightingAdvice.self,
            from: JSONEncoder().encode(advice)
        )
        #expect(decodedAdvice == advice)

        let decodedContext = try JSONDecoder().decode(
            AdviceContext.self,
            from: JSONEncoder().encode(context)
        )
        #expect(decodedContext == context)
    }

    @Test("Decodes a schema-conformant tool payload, optional fields omitted")
    func decodesToolPayload() throws {
        let payload = """
        {
          "sceneSummary": "無窗隔間，天花板日光燈為主。",
          "offsets": [
            {"displayID": "display:asus", "offset": 0.08, "reason": "視野背景較亮"}
          ],
          "warnings": ["gamma 螢幕請先用 OSD 設定硬體背光上限"]
        }
        """
        let advice = try JSONDecoder().decode(LightingAdvice.self, from: Data(payload.utf8))
        #expect(advice.offsets.count == 1)
        #expect(advice.maxLux == nil)
        #expect(advice.minBrightness == nil)
        #expect(advice.sanitized(for: context) == advice)
    }
}
