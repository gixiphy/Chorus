import Foundation
import Testing
@testable import ChorusCore

@Suite("Advice prompt")
struct AdvicePromptTests {
    @Test("Tool schema is valid JSON matching LightingAdvice coding keys")
    func schemaShape() throws {
        let object = try JSONSerialization.jsonObject(
            with: Data(AdvicePrompt.toolInputSchemaJSON(responseLanguage: "English").utf8)
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

    @Test("System prompt states output discipline, tool name and the response language")
    func systemPromptContent() {
        let prompt = AdvicePrompt.systemPrompt(responseLanguage: "Chinese (Traditional)")
        #expect(prompt.contains(AdvicePrompt.toolName))
        #expect(prompt.contains("gamma"))
        #expect(prompt.contains("0.15"))
        #expect(prompt.contains("write all text in Chinese (Traditional)"))
        // prompt 本體是英文；只有回覆語言跟著介面走
        #expect(!prompt.contains("繁體中文"))
    }

    @Test("Schema descriptions carry the response language")
    func schemaCarriesLanguage() {
        let schema = AdvicePrompt.toolInputSchemaJSON(responseLanguage: "Japanese")
        #expect(schema.contains("One-sentence reason in Japanese"))
    }

    @Test("Response language name comes from the localization identifier")
    func languageName() {
        #expect(AdviceLanguage.name(forLocalization: "en") == "English")
        #expect(AdviceLanguage.name(forLocalization: "zh-Hant").contains("Chinese"))
        // 不認得的代碼原樣回傳，prompt 不會變空
        #expect(AdviceLanguage.name(forLocalization: "x-unknown") == "x-unknown")
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
        Displays:
        - id=display:builtin name="內建螢幕" backend=displayServices photoPosition=(0.45, 0.70) currentOffset=+0.02
        - id=display:asus name="ASUS VS207" backend=gamma photoPosition=not placed currentOffset=+0.00
        Current curve: minBrightness=0.15 maxLux=800
        Recent ambient light (lux): min=12 median=180 max=420
        User note: the desk has a monitor light bar
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
        #expect(description.contains("Recent ambient light: no data"))
        #expect(!description.contains("User note"))
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
            readInstruction: "read the photo before analyzing"
        )
        // 標註是使用者原話，不翻譯，原樣夾帶
        #expect(prompt.contains("1. /tmp/a.jpg (lighting scenario: 白天，窗簾拉開)"))
        // 未標註的維持只有路徑，不留空括號
        #expect(prompt.contains("2. /tmp/b.jpg\n"))
        // 前後空白在送進 prompt 前才 trim（輸入時保留，否則空白鍵按不出來）
        #expect(prompt.contains("3. /tmp/c.jpg (lighting scenario: 夜晚，只開掛燈)"))
    }

    @Test("Single unlabeled photo keeps the pre-label wording")
    func singlePhotoWordingUnchanged() {
        let prompt = AdvicePrompt.cliPrompt(
            context: emptyContext,
            photos: [LabeledPhoto(path: "/tmp/desk.jpg")],
            readInstruction: "read it with the Read tool before analyzing"
        )
        #expect(prompt.contains("Desk photo: /tmp/desk.jpg (read it with the Read tool before analyzing)"))
    }

    @Test("Single labeled photo carries its label")
    func singlePhotoWithLabel() {
        let prompt = AdvicePrompt.cliPrompt(
            context: emptyContext,
            photos: [LabeledPhoto(path: "/tmp/desk.jpg", label: "夜晚，只開掛燈")],
            readInstruction: "read it with the Read tool before analyzing"
        )
        #expect(prompt.contains("Desk photo: /tmp/desk.jpg (lighting scenario: 夜晚，只開掛燈) (read it with the Read tool before analyzing)"))
    }
}
