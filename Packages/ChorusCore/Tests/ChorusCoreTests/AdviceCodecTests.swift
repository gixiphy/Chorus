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
        photos: [LabeledPhoto(path: "/tmp/desk.jpg")],
        readInstruction: "用 Read 工具讀取後再分析"
    )
    #expect(prompt.contains(AdvicePrompt.systemPrompt()))
    #expect(prompt.contains("id=display:AAA"))
    #expect(prompt.contains("Desk photo: /tmp/desk.jpg (用 Read 工具讀取後再分析)"))
    #expect(prompt.contains(AdvicePrompt.toolInputSchemaJSON()))
}

@Test("cliPrompt：多張照片列編號清單，標注第一張為背景照")
func cliPromptMultiPhoto() {
    let context = AdviceContext(
        displays: [.init(id: "display:AAA", name: "內建", backend: "displayServices")],
        curve: AmbientCurve()
    )
    let prompt = AdvicePrompt.cliPrompt(
        context: context,
        photos: ["/tmp/a.jpg", "/tmp/b.jpg", "/tmp/c.jpg"].map { LabeledPhoto(path: $0) },
        readInstruction: "用 Read 工具讀取後再分析"
    )
    // prompt 自 20ef44b 起全文英文——這兩條當時漏改
    #expect(prompt.contains("3 desk photos"))
    #expect(prompt.contains("photo 1 is the layout background"))
    #expect(prompt.contains("1. /tmp/a.jpg"))
    #expect(prompt.contains("3. /tmp/c.jpg"))
}

@Suite("responseEnvelope codec（agy）")
struct ResponseEnvelopeCodecTests {
    @Test("優先吃 structured_output——CLI 依 --json-schema 驗過的結果")
    func prefersStructuredOutput() throws {
        // response 文字刻意放不一樣的內容：若解析走錯路徑，斷言會抓到
        let stdout = """
        {"status":"SUCCESS","response":"這段文字不該被採用",
         "structured_output":{"sceneSummary":"來自 structured_output",
         "offsets":[{"displayID":"display:A","offset":0.1,"reason":"r"}],"warnings":[]}}
        """
        let advice = try AdviceCodec.decode(stdout: stdout, codec: .responseEnvelope)
        #expect(advice.sceneSummary == "來自 structured_output")
        #expect(advice.offsets.count == 1)
    }

    /// envelope 以 JSONSerialization 組，內層引號的逃逸交給它——
    /// 手寫巢狀 JSON 字面值極易寫錯，測到的會是測資而不是程式。
    private func envelope(response: String) -> String {
        let object: [String: Any] = ["status": "SUCCESS", "response": response]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    @Test("沒有 structured_output 時退回 response 文字")
    func fallsBackToResponseText() throws {
        let inner = #"{"sceneSummary":"來自 response","offsets":[],"warnings":[]}"#
        let advice = try AdviceCodec.decode(
            stdout: envelope(response: inner), codec: .responseEnvelope
        )
        #expect(advice.sceneSummary == "來自 response")
    }

    @Test("response 文字外包 fence 也剝得掉")
    func stripsFenceInResponse() throws {
        let inner = "```json\n" + #"{"sceneSummary":"F","offsets":[],"warnings":[]}"# + "\n```"
        let advice = try AdviceCodec.decode(
            stdout: envelope(response: inner), codec: .responseEnvelope
        )
        #expect(advice.sceneSummary == "F")
    }

    @Test("status 是 SUCCESS 但 response 為空 → emptyOutput（實測的權限被拒形狀）")
    func emptyResponseDespiteSuccessStatus() {
        // agy 1.1.19 headless read_file 被拒時就是這個形狀：
        // 退出碼 0、status SUCCESS、response 空字串，原因只在 stderr。
        // 若信 status 就會把失敗當成功，是這個 codec 最關鍵的一條。
        #expect(throws: AdviceDecodeError.emptyOutput) {
            try AdviceCodec.decode(
                stdout: #"{"status":"SUCCESS","response":""}"#,
                codec: .responseEnvelope
            )
        }
        // 只有空白／換行也算空
        let whitespaceOnly = "{\"status\":\"SUCCESS\",\"response\":\"  \\n \"}"
        #expect(throws: AdviceDecodeError.emptyOutput) {
            try AdviceCodec.decode(stdout: whitespaceOnly, codec: .responseEnvelope)
        }
    }

    @Test("structured_output 存在但形狀不符 → 直接失敗，不偷偷退回文字路徑")
    func malformedStructuredOutputFailsLoud() {
        #expect(throws: AdviceDecodeError.self) {
            try AdviceCodec.decode(
                stdout: #"{"status":"SUCCESS","response":"x","structured_output":{"nope":1}}"#,
                codec: .responseEnvelope
            )
        }
    }

    @Test("envelope 不是合法 JSON → envelopeParseFailed")
    func malformedEnvelope() {
        #expect(throws: AdviceDecodeError.self) {
            try AdviceCodec.decode(stdout: "not json at all", codec: .responseEnvelope)
        }
    }
}

@Suite("JSON 夾在旁白中的擷取")
struct EmbeddedJSONTests {
    private let valid = #"{"sceneSummary":"S","offsets":[],"warnings":[]}"#

    @Test("模型在 JSON 前加旁白仍解析得出（實測 grok 會這樣）")
    func narrationBeforeJSON() throws {
        let text = "先讀取桌面照片，再依光環境提出建議。\n" + valid
        let advice = try AdviceCodec.decode(stdout: text, codec: .plainStdout)
        #expect(advice.sceneSummary == "S")
    }

    @Test("旁白在前後都有也可以")
    func narrationAround() throws {
        let advice = try AdviceCodec.decode(
            stdout: "開始。\n" + valid + "\n以上是我的建議。", codec: .plainStdout
        )
        #expect(advice.sceneSummary == "S")
    }

    @Test("字串字面值裡的大括號不影響深度計算")
    func bracesInsideStrings() {
        let text = #"prefix {"a":"has { brace","b":{"c":1}} suffix"#
        #expect(AdviceCodec.firstJSONObject(in: text) == #"{"a":"has { brace","b":{"c":1}}"#)
    }

    @Test("逃逸的引號不會誤判字串結束")
    func escapedQuotes() {
        let text = #"{"a":"say \"hi\"","b":1}"#
        #expect(AdviceCodec.firstJSONObject(in: text) == text)
    }

    @Test("沒有成對括號時回 nil，不硬湊")
    func unbalanced() {
        #expect(AdviceCodec.firstJSONObject(in: "no json here") == nil)
        #expect(AdviceCodec.firstJSONObject(in: "{ unclosed") == nil)
    }

    @Test("完全沒有可解析的 JSON 仍照常丟 adviceParseFailed")
    func stillFailsLoud() {
        #expect(throws: AdviceDecodeError.self) {
            try AdviceCodec.decode(stdout: "抱歉，我無法完成。", codec: .plainStdout)
        }
    }
}
