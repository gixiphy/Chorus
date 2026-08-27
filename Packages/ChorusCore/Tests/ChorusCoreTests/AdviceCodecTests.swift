import ChorusCore
import Foundation
import Testing

private let validAdviceJSON = """
{"sceneSummary":"無窗隔間，天花板日光燈。","offsets":[{"displayID":"display:AAA","offset":0.1,"reason":"背景較亮"}],"warnings":["掛燈請關自動模式"]}
"""

private func envelope(result: String, isError: Bool = false) -> String {
    let object: [String: Any] = ["type": "result", "is_error": isError, "result": result]
    let data = try! JSONSerialization.data(withJSONObject: object)
    return String(data: data, encoding: .utf8)!
}

@Test("jsonEnvelope：取 result 欄位並 decode")
func envelopeDecode() throws {
    let advice = try AdviceCodec.decode(stdout: envelope(result: validAdviceJSON), codec: .jsonEnvelope)
    #expect(advice.offsets.count == 1)
    #expect(advice.offsets[0].displayID == "display:AAA")
    #expect(advice.sceneSummary == "無窗隔間，天花板日光燈。")
}

@Test("jsonEnvelope：result 被 code fence 包住也能解")
func envelopeWithFence() throws {
    let fenced = "```json\n\(validAdviceJSON)\n```"
    let advice = try AdviceCodec.decode(stdout: envelope(result: fenced), codec: .jsonEnvelope)
    #expect(advice.offsets.count == 1)
}

@Test("plainStdout：整段輸出直接 decode（含 fence 與前後空白）")
func plainStdoutDecode() throws {
    let stdout = "\n```\n\(validAdviceJSON)\n```\n"
    let advice = try AdviceCodec.decode(stdout: stdout, codec: .plainStdout)
    #expect(advice.warnings == ["掛燈請關自動模式"])
}

@Test("空輸出 → emptyOutput")
func emptyOutput() {
    #expect(throws: AdviceDecodeError.emptyOutput) {
        try AdviceCodec.decode(stdout: "  \n", codec: .plainStdout)
    }
}

@Test("envelope 不是 JSON → envelopeParseFailed 帶原文")
func envelopeParseFailure() {
    #expect(throws: AdviceDecodeError.envelopeParseFailed(raw: "not json at all")) {
        try AdviceCodec.decode(stdout: "not json at all", codec: .jsonEnvelope)
    }
}

@Test("envelope is_error → cliReportedError 帶訊息")
func envelopeIsError() {
    #expect(throws: AdviceDecodeError.cliReportedError(message: "Invalid API key")) {
        try AdviceCodec.decode(stdout: envelope(result: "Invalid API key", isError: true), codec: .jsonEnvelope)
    }
}

@Test("回應非 advice JSON → adviceParseFailed 帶回應原文")
func adviceParseFailure() {
    #expect(throws: AdviceDecodeError.adviceParseFailed(raw: "抱歉，我無法分析這張照片。")) {
        try AdviceCodec.decode(stdout: envelope(result: "抱歉，我無法分析這張照片。"), codec: .jsonEnvelope)
    }
}

@Test("strippingCodeFence：無 fence 原樣、有語言標記可剝、只剝最外層")
func fenceStripping() {
    #expect(AdviceCodec.strippingCodeFence("{\"a\":1}") == "{\"a\":1}")
    #expect(AdviceCodec.strippingCodeFence("```json\n{\"a\":1}\n```") == "{\"a\":1}")
    #expect(AdviceCodec.strippingCodeFence("```\n{\"a\":1}\n```  ") == "{\"a\":1}")
}

@Test("cliPrompt：含系統提示、context、照片路徑與 schema")
func cliPromptAssembly() {
    let context = AdviceContext(
        displays: [.init(id: "display:AAA", name: "內建", backend: "displayServices")],
        curve: AmbientCurve()
    )
    let prompt = AdvicePrompt.cliPrompt(
        context: context,
        photoPath: "/tmp/desk.jpg",
        readInstruction: "用 Read 工具讀取後再分析"
    )
    #expect(prompt.contains(AdvicePrompt.systemPrompt))
    #expect(prompt.contains("id=display:AAA"))
    #expect(prompt.contains("桌面照片：/tmp/desk.jpg（用 Read 工具讀取後再分析）"))
    #expect(prompt.contains(AdvicePrompt.toolInputSchemaJSON))
}
