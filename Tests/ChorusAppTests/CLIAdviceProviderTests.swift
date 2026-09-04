import ChorusCore
import Foundation
import Testing
@testable import Chorus

/// CLIAdviceProvider 以假執行檔（stub script）測：參數組裝、envelope 解析、
/// fence 剝除、逾時、錯誤映射、decode 失敗重試（設計文件 §7）。
@Suite("CLI advice provider")
struct CLIAdviceProviderTests {
    private static let validAdviceJSON = """
    {"sceneSummary":"測試場景","offsets":[{"displayID":"display:AAA","offset":0.1,"reason":"理由"}],"warnings":[]}
    """

    /// 嵌進 envelope 的字串欄位時要先逃逸引號（shell 單引號會原樣保留反斜線）。
    private static let escapedAdviceJSON =
        validAdviceJSON.replacingOccurrences(of: "\"", with: "\\\"")

    private let context = AdviceContext(
        displays: [.init(id: "display:AAA", name: "內建", backend: "displayServices")],
        curve: AmbientCurve()
    )

    private func makeStub(_ script: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-cli-stub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("stub")
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func claudeEngine() -> KnownCLIEngine {
        KnownCLIEngine.catalog.first { $0.id == "claude" }!
    }

    /// envelope JSON 由 stub 以單引號 heredoc 輸出，避免 shell 轉義問題。
    private func envelopeScript(result: String) -> String {
        let envelope: [String: Any] = ["type": "result", "is_error": false, "result": result]
        let data = try! JSONSerialization.data(withJSONObject: envelope)
        let json = String(data: data, encoding: .utf8)!
        return """
        cat > /dev/null
        cat <<'CHORUS_EOF'
        \(json)
        CHORUS_EOF
        """
    }

    @Test("成功路徑：stdin 收 prompt、stdout envelope → advice")
    func successPath() async throws {
        let stub = try makeStub(envelopeScript(result: Self.validAdviceJSON))
        let provider = CLIAdviceProvider(engine: claudeEngine(), executable: stub)
        let advice = try await provider.advise(photos: [LabeledPhoto(path: "/tmp/desk.jpg")], context: context, sandbox: nil)
        #expect(advice.offsets.count == 1)
        #expect(advice.offsets[0].displayID == "display:AAA")
    }

    @Test("prompt 組裝：claude 引擎經 stdin 傳遞，含照片路徑、schema 與 Read 指示")
    func promptAssembly() async throws {
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-prompt-\(UUID().uuidString).txt")
        let stub = try makeStub("""
        cat > "\(capture.path)"
        \(envelopeScript(result: Self.validAdviceJSON).replacingOccurrences(of: "cat > /dev/null\n", with: ""))
        """)
        let provider = CLIAdviceProvider(engine: claudeEngine(), executable: stub)
        _ = try await provider.advise(photos: [LabeledPhoto(path: "/tmp/desk-photo.jpg")], context: context, sandbox: nil)
        let prompt = try String(contentsOf: capture, encoding: .utf8)
        #expect(prompt.contains("Desk photo: /tmp/desk-photo.jpg (read it with the Read tool before analyzing)"))
        #expect(prompt.contains("JSON Schema"))
        #expect(prompt.contains("id=display:AAA"))
        try? FileManager.default.removeItem(at: capture)
    }

    @Test("result 帶 code fence 也能解")
    func fenceInResult() async throws {
        let fenced = "```json\n\(Self.validAdviceJSON)\n```"
        let stub = try makeStub(envelopeScript(result: fenced))
        let provider = CLIAdviceProvider(engine: claudeEngine(), executable: stub)
        let advice = try await provider.advise(photos: [LabeledPhoto(path: "/tmp/a.jpg")], context: context, sandbox: nil)
        #expect(advice.sceneSummary == "測試場景")
    }

    @Test("非零退出＋認證字樣 → notLoggedIn")
    func authErrorMapping() async throws {
        let stub = try makeStub("""
        cat > /dev/null
        echo "Please run claude login first" >&2
        exit 1
        """)
        let provider = CLIAdviceProvider(engine: claudeEngine(), executable: stub)
        do {
            _ = try await provider.advise(photos: [LabeledPhoto(path: "/tmp/a.jpg")], context: context, sandbox: nil)
            Issue.record("預期丟錯")
        } catch let error as AdviceError {
            guard case .notLoggedIn = error else {
                Issue.record("預期 notLoggedIn，得到 \(error)")
                return
            }
        }
    }

    @Test("非零退出＋stdout envelope 帶 401 → notLoggedIn（claude 出錯時 stderr 是空的）")
    func authErrorInStdoutEnvelope() async throws {
        let stub = try makeStub("""
        cat > /dev/null
        echo '{"type":"result","is_error":true,"result":"Failed to authenticate. API Error: 401 OAuth access token has been revoked."}'
        exit 1
        """)
        let provider = CLIAdviceProvider(engine: claudeEngine(), executable: stub)
        do {
            _ = try await provider.advise(photos: [LabeledPhoto(path: "/tmp/a.jpg")], context: context, sandbox: nil)
            Issue.record("預期丟錯")
        } catch let error as AdviceError {
            guard case .notLoggedIn = error else {
                Issue.record("預期 notLoggedIn，得到 \(error)")
                return
            }
        }
    }

    @Test("非零退出＋stderr 空白 → 從 stdout envelope 取錯誤訊息")
    func stdoutEnvelopeFallbackMessage() async throws {
        let stub = try makeStub("""
        cat > /dev/null
        echo '{"type":"result","is_error":true,"result":"模型服務暫時無法使用"}'
        exit 1
        """)
        let provider = CLIAdviceProvider(engine: claudeEngine(), executable: stub)
        do {
            _ = try await provider.advise(photos: [LabeledPhoto(path: "/tmp/a.jpg")], context: context, sandbox: nil)
            Issue.record("預期丟錯")
        } catch let error as AdviceError {
            guard case let .processFailed(status, message) = error else {
                Issue.record("預期 processFailed，得到 \(error)")
                return
            }
            #expect(status == 1)
            #expect(message.contains("模型服務暫時無法使用"))
        }
    }

    @Test("非零退出＋一般錯誤 → processFailed 帶 stderr")
    func genericErrorMapping() async throws {
        let stub = try makeStub("""
        cat > /dev/null
        echo "something exploded" >&2
        exit 3
        """)
        let provider = CLIAdviceProvider(engine: claudeEngine(), executable: stub)
        do {
            _ = try await provider.advise(photos: [LabeledPhoto(path: "/tmp/a.jpg")], context: context, sandbox: nil)
            Issue.record("預期丟錯")
        } catch let error as AdviceError {
            guard case let .processFailed(status, stderr) = error else {
                Issue.record("預期 processFailed，得到 \(error)")
                return
            }
            #expect(status == 3)
            #expect(stderr.contains("something exploded"))
        }
    }

    @Test("逾時 → 終止子行程並丟 timedOut")
    func timeout() async throws {
        let stub = try makeStub("""
        cat > /dev/null
        sleep 30
        """)
        var provider = CLIAdviceProvider(engine: claudeEngine(), executable: stub)
        provider.timeout = .milliseconds(500)
        let started = Date()
        do {
            _ = try await provider.advise(photos: [LabeledPhoto(path: "/tmp/a.jpg")], context: context, sandbox: nil)
            Issue.record("預期丟錯")
        } catch let error as AdviceError {
            guard case .timedOut = error else {
                Issue.record("預期 timedOut，得到 \(error)")
                return
            }
        }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test("decode 失敗自動重試一次：第二次成功")
    func retryOnDecodeFailure() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-retry-\(UUID().uuidString)")
        let stub = try makeStub("""
        cat > /dev/null
        if [ -f "\(marker.path)" ]; then
        \(envelopeScript(result: Self.validAdviceJSON).replacingOccurrences(of: "cat > /dev/null\n", with: ""))
        else
          touch "\(marker.path)"
          echo '{"type":"result","is_error":false,"result":"這不是 JSON"}'
        fi
        """)
        let provider = CLIAdviceProvider(engine: claudeEngine(), executable: stub)
        let advice = try await provider.advise(photos: [LabeledPhoto(path: "/tmp/a.jpg")], context: context, sandbox: nil)
        #expect(advice.offsets.count == 1)
        try? FileManager.default.removeItem(at: marker)
    }

    @Test("兩次都失敗 → decodeFailed 帶模型原文")
    func decodeFailureAfterRetry() async throws {
        let stub = try makeStub("""
        cat > /dev/null
        echo '{"type":"result","is_error":false,"result":"抱歉我做不到"}'
        """)
        let provider = CLIAdviceProvider(engine: claudeEngine(), executable: stub)
        do {
            _ = try await provider.advise(photos: [LabeledPhoto(path: "/tmp/a.jpg")], context: context, sandbox: nil)
            Issue.record("預期丟錯")
        } catch let error as AdviceError {
            guard case let .decodeFailed(raw) = error else {
                Issue.record("預期 decodeFailed，得到 \(error)")
                return
            }
            #expect(raw.contains("抱歉我做不到"))
        }
    }

    /// 把整組 argv 逐行寫出來，斷言各引擎的呼叫契約。
    private func captureArgv(engineID: String, photos: [String]) async throws -> [String] {
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-argv-\(UUID().uuidString).txt")
        let stub = try makeStub("""
        printf '%s@@ARG@@' "$@" > "\(capture.path)"
        cat <<'CHORUS_EOF'
        \(Self.validAdviceJSON)
        CHORUS_EOF
        """)
        let engine = KnownCLIEngine.catalog.first { $0.id == engineID }!
        let provider = CLIAdviceProvider(engine: engine, executable: stub)
        _ = try await provider.advise(
            photos: photos.map { LabeledPhoto(path: $0) },
            context: context,
            sandbox: nil
        )
        let argv = try String(contentsOf: capture, encoding: .utf8)
            .components(separatedBy: "@@ARG@@")
            .dropLast() // printf 在最後一個引數後也會補一個分隔符
            .map { $0 }
        try? FileManager.default.removeItem(at: capture)
        return argv
    }

    @Test("codex：影像以 --image 直接附加，prompt 排最後")
    func codexAttachesImages() async throws {
        let argv = try await captureArgv(engineID: "codex", photos: ["/tmp/a.jpg", "/tmp/b.jpg"])
        #expect(argv.first == "exec")
        // 每張圖一組 --image <path>
        for path in ["/tmp/a.jpg", "/tmp/b.jpg"] {
            guard let index = argv.firstIndex(of: path) else {
                Issue.record("argv 缺少 \(path)")
                return
            }
            #expect(argv[index - 1] == "--image")
        }
        // 沙箱目錄不是 git repo，少了這個旗標 codex 會直接拒跑
        #expect(argv.contains("--skip-git-repo-check"))
        #expect(argv.contains("read-only"))
        // 附加模式的 prompt 不該再叫模型去讀某個路徑
        let prompt = argv.last ?? ""
        #expect(prompt.contains("attached to this message"))
        // 附加模式不該再把路徑寫進 prompt——模型已經看得到圖，
        // 叫它去讀路徑只會誘發多餘（且會被權限擋下）的工具呼叫
        #expect(!prompt.contains("/tmp/a.jpg"))
    }

    @Test("pi：照片以 @path 附加且排在 prompt 前，探索旗標齊全")
    func piAttachesPhotosAndDisablesExploration() async throws {
        let argv = try await captureArgv(engineID: "pi", photos: ["/tmp/a.jpg", "/tmp/b.jpg"])
        #expect(argv.first == "-p")
        for flag in ["--no-session", "--no-tools", "--no-context-files",
                     "--no-extensions", "--no-skills", "--no-prompt-templates"] {
            #expect(argv.contains(flag), "缺少 \(flag)：\(argv)")
        }
        guard let firstPhoto = argv.firstIndex(of: "@/tmp/a.jpg"),
              let secondPhoto = argv.firstIndex(of: "@/tmp/b.jpg"),
              let prompt = argv.firstIndex(where: { $0.contains("attached to this message") })
        else {
            Issue.record("argv 形狀不符：\(argv)")
            return
        }
        // 實測：@檔案必須排在訊息前（與 opencode 的 -f 相反方向）
        #expect(firstPhoto < prompt)
        #expect(secondPhoto < prompt)
        #expect(argv.last?.contains("attached to this message") == true)
        // 附加模式不該再把路徑寫進 prompt
        let promptText = argv.last ?? ""
        #expect(!promptText.contains("/tmp/a.jpg"))
    }

    @Test("pi：有模型時帶 --model，@path 仍排在 prompt 前")
    func piInvocationIncludesModel() {
        let engine = KnownCLIEngine.catalog.first { $0.id == "pi" }!
        let run = KnownCLIEngine.RunContext(
            sandbox: nil,
            schemaFile: nil,
            model: "opencode-go/kimi-k2.7-code",
            photoPaths: ["/tmp/a.jpg"]
        )
        let (arguments, stdin) = engine.invocation(prompt: "analyze this", run: run)
        #expect(stdin == nil)
        #expect(arguments.first == "-p")
        guard let modelFlag = arguments.firstIndex(of: "--model"),
              let photo = arguments.firstIndex(of: "@/tmp/a.jpg"),
              let prompt = arguments.firstIndex(of: "analyze this")
        else {
            Issue.record("argv 形狀不符：\(arguments)")
            return
        }
        #expect(arguments[modelFlag + 1] == "opencode-go/kimi-k2.7-code")
        #expect(modelFlag < photo)
        #expect(photo < prompt)
    }

    @Test("opencode：訊息必須排在 -f 前面，否則會被當成檔案路徑吃掉")
    func opencodeArgumentOrder() async throws {
        let argv = try await captureArgv(engineID: "opencode", photos: ["/tmp/a.jpg"])
        #expect(argv.first == "run")
        guard let fileFlag = argv.firstIndex(of: "-f"),
              let prompt = argv.firstIndex(where: { $0.contains("attached to this message") })
        else {
            Issue.record("argv 形狀不符：\(argv)")
            return
        }
        // 實測：訊息排在 -f 後面會得到 "File not found: <整段訊息>"
        #expect(prompt < fileFlag)
        #expect(argv[fileFlag + 1] == "/tmp/a.jpg")
    }

    @Test("agy：以 --add-dir 明示授權沙箱，並帶上 schema 檔")
    func agyGrantsSandbox() async throws {
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-agy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        let capture = sandbox.appendingPathComponent("argv.txt")
        let stub = try makeStub("""
        printf '%s@@ARG@@' "$@" > "\(capture.path)"
        printf '%s' '{"status":"SUCCESS","response":"\(Self.escapedAdviceJSON)"}'
        """)
        let agy = KnownCLIEngine.catalog.first { $0.id == "agy" }!
        let provider = CLIAdviceProvider(engine: agy, executable: stub)
        _ = try await provider.advise(
            photos: [LabeledPhoto(path: sandbox.appendingPathComponent("p.jpg").path)],
            context: context,
            sandbox: sandbox
        )
        let argv = try String(contentsOf: capture, encoding: .utf8)
            .components(separatedBy: "@@ARG@@").dropLast().map { $0 }
        guard let addDir = argv.firstIndex(of: "--add-dir") else {
            Issue.record("缺少 --add-dir：\(argv)")
            return
        }
        #expect(argv[addDir + 1] == sandbox.path)
        // 絕不使用全域放行
        #expect(!argv.contains("--dangerously-skip-permissions"))
        #expect(argv.contains("--json-schema"))
    }

    @Test("grok：textEnvelope 取 text 欄位")
    func grokTextEnvelope() async throws {
        let stub = try makeStub("""
        printf '%s' '{"text":"\(Self.escapedAdviceJSON)","stopReason":"end_turn"}'
        """)
        let grok = KnownCLIEngine.catalog.first { $0.id == "grok" }!
        let provider = CLIAdviceProvider(engine: grok, executable: stub)
        let advice = try await provider.advise(
            photos: [LabeledPhoto(path: "/tmp/a.jpg")], context: context, sandbox: nil
        )
        #expect(advice.offsets.count == 1)
    }

    @Test("退出碼 0 但回應為空 → emptyResponse，並把 stderr 的原因接出來")
    func emptyResponseSurfacesStderr() async throws {
        let stub = try makeStub("""
        echo 'a tool required the "read_file" permission that headless mode cannot prompt for' >&2
        printf '%s' '{"status":"SUCCESS","response":""}'
        """)
        let agy = KnownCLIEngine.catalog.first { $0.id == "agy" }!
        let provider = CLIAdviceProvider(engine: agy, executable: stub)
        do {
            _ = try await provider.advise(
                photos: [LabeledPhoto(path: "/tmp/a.jpg")], context: context, sandbox: nil
            )
            Issue.record("預期丟錯")
        } catch let error as AdviceError {
            guard case let .emptyResponse(engineID, detail) = error else {
                Issue.record("預期 emptyResponse，得到 \(error)")
                return
            }
            #expect(engineID == "agy")
            #expect(detail.contains("read_file"))
        }
    }
}
