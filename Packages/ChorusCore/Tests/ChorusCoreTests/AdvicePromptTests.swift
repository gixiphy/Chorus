import Foundation
import Testing
@testable import ChorusCore

@Suite("Advice prompt")
struct AdvicePromptTests {
    @Test("Tool schema is valid JSON matching LightingAdvice coding keys")
    func schemaShape() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(AdvicePrompt.toolInputSchemaJSON.utf8)
        ) as? [String: Any]
        let schema = try #require(object)
        let properties = try #require(schema["properties"] as? [String: Any])
        #expect(Set(properties.keys) == ["sceneSummary", "offsets", "maxLux", "minBrightness", "warnings"])

        let required = try #require(schema["required"] as? [String])
        #expect(Set(required) == ["sceneSummary", "offsets", "warnings"])

        let offsets = try #require(properties["offsets"] as? [String: Any])
        let items = try #require(offsets["items"] as? [String: Any])
        let itemProperties = try #require(items["properties"] as? [String: Any])
        #expect(Set(itemProperties.keys) == ["displayID", "offset", "reason"])

        // schema 的數值範圍與 sanitized 的夾值範圍必須一致
        let offsetBounds = try #require(itemProperties["offset"] as? [String: Any])
        #expect(offsetBounds["minimum"] as? Double == LightingAdvice.offsetRange.lowerBound)
        #expect(offsetBounds["maximum"] as? Double == LightingAdvice.offsetRange.upperBound)
        let maxLux = try #require(properties["maxLux"] as? [String: Any])
        #expect(maxLux["minimum"] as? Double == LightingAdvice.maxLuxRange.lowerBound)
        #expect(maxLux["maximum"] as? Double == LightingAdvice.maxLuxRange.upperBound)
        let minBrightness = try #require(properties["minBrightness"] as? [String: Any])
        #expect(minBrightness["minimum"] as? Double == LightingAdvice.minBrightnessRange.lowerBound)
        #expect(minBrightness["maximum"] as? Double == LightingAdvice.minBrightnessRange.upperBound)
    }

    @Test("System prompt states output discipline and tool name")
    func systemPromptContent() {
        let prompt = AdvicePrompt.systemPrompt
        #expect(prompt.contains(AdvicePrompt.toolName))
        #expect(prompt.contains("gamma"))
        #expect(prompt.contains("0.15"))
        #expect(prompt.contains("繁體中文"))
    }

    @Test("Context description lists displays, curve and lux stats deterministically")
    func contextDescription() {
        let context = AdviceContext(
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
            recentLux: LuxStats(minLux: 12, medianLux: 180, maxLux: 420),
            hasLightBarHint: true
        )
        let description = AdvicePrompt.contextDescription(context)
        let expected = """
        顯示器清單：
        - id=display:builtin 名稱=「內建螢幕」 backend=displayServices 照片座標=(0.45, 0.70) 目前offset=+0.02
        - id=display:asus 名稱=「ASUS VS207」 backend=gamma 照片座標=未擺放 目前offset=+0.00
        現行曲線：minBrightness=0.15 maxLux=800
        近期環境光（lux）：min=12 median=180 max=420
        使用者標注：桌面有螢幕掛燈
        """
        #expect(description == expected)
    }

    @Test("Context description handles missing lux stats and hint")
    func contextDescriptionWithoutOptionals() {
        let context = AdviceContext(
            displays: [.init(id: "display:mini", name: "Mini", backend: "ddc")],
            curve: AmbientCurve()
        )
        let description = AdvicePrompt.contextDescription(context)
        #expect(description.contains("近期環境光：無資料"))
        #expect(!description.contains("使用者標注"))
    }

    private var emptyContext: AdviceContext {
        AdviceContext(displays: [], curve: AmbientCurve())
    }

    @Test("Multi-photo prompt appends labels and leaves unlabeled photos bare")
    func labeledPhotoListing() {
        let prompt = AdvicePrompt.cliPrompt(
            context: emptyContext,
            photos: [
                LabeledPhoto(path: "/tmp/a.jpg", label: "白天，窗簾拉開"),
                LabeledPhoto(path: "/tmp/b.jpg"),
                LabeledPhoto(path: "/tmp/c.jpg", label: "  夜晚，只開掛燈  ")
            ],
            readInstruction: "請先讀取照片再分析"
        )
        #expect(prompt.contains("1. /tmp/a.jpg（照明情境：白天，窗簾拉開）"))
        // 未標註的維持只有路徑，不留空括號
        #expect(prompt.contains("2. /tmp/b.jpg\n"))
        // 前後空白在送進 prompt 前才 trim（輸入時保留，否則空白鍵按不出來）
        #expect(prompt.contains("3. /tmp/c.jpg（照明情境：夜晚，只開掛燈）"))
    }

    @Test("Single unlabeled photo keeps the pre-label wording")
    func singlePhotoWordingUnchanged() {
        let prompt = AdvicePrompt.cliPrompt(
            context: emptyContext,
            photos: [LabeledPhoto(path: "/tmp/desk.jpg")],
            readInstruction: "用 Read 工具讀取後再分析"
        )
        #expect(prompt.contains("桌面照片：/tmp/desk.jpg（用 Read 工具讀取後再分析）"))
    }

    @Test("Single labeled photo carries its label")
    func singlePhotoWithLabel() {
        let prompt = AdvicePrompt.cliPrompt(
            context: emptyContext,
            photos: [LabeledPhoto(path: "/tmp/desk.jpg", label: "夜晚，只開掛燈")],
            readInstruction: "用 Read 工具讀取後再分析"
        )
        #expect(prompt.contains("桌面照片：/tmp/desk.jpg（照明情境：夜晚，只開掛燈）（用 Read 工具讀取後再分析）"))
    }
}
