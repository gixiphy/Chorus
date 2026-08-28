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
        let advice = try await provider.advise(photoPaths: ["/tmp/desk.jpg"], context: context)
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
        _ = try await provider.advise(photoPaths: ["/tmp/desk-photo.jpg"], context: context)
        let prompt = try String(contentsOf: capture, encoding: .utf8)
        #expect(prompt.contains("桌面照片：/tmp/desk-photo.jpg（用 Read 工具讀取後再分析）"))
        #expect(prompt.contains("JSON Schema"))
        #expect(prompt.contains("id=display:AAA"))
        try? FileManager.default.removeItem(at: capture)
    }

    @Test("result 帶 code fence 也能解")
    func fenceInResult() async throws {
        let fenced = "```json\n\(Self.validAdviceJSON)\n```"
        let stub = try makeStub(envelopeScript(result: fenced))
        let provider = CLIAdviceProvider(engine: claudeEngine(), executable: stub)
        let advice = try await provider.advise(photoPaths: ["/tmp/a.jpg"], context: context)
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
            _ = try await provider.advise(photoPaths: ["/tmp/a.jpg"], context: context)
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
            _ = try await provider.advise(photoPaths: ["/tmp/a.jpg"], context: context)
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
            _ = try await provider.advise(photoPaths: ["/tmp/a.jpg"], context: context)
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
            _ = try await provider.advise(photoPaths: ["/tmp/a.jpg"], context: context)
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
            _ = try await provider.advise(photoPaths: ["/tmp/a.jpg"], context: context)
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
        let advice = try await provider.advise(photoPaths: ["/tmp/a.jpg"], context: context)
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
            _ = try await provider.advise(photoPaths: ["/tmp/a.jpg"], context: context)
            Issue.record("預期丟錯")
        } catch let error as AdviceError {
            guard case let .decodeFailed(raw) = error else {
                Issue.record("預期 decodeFailed，得到 \(error)")
                return
            }
            #expect(raw.contains("抱歉我做不到"))
        }
    }

    @Test("plainStdout 引擎：prompt 走 argv、整段 stdout 直接 decode")
    func plainStdoutEngine() async throws {
        let capture = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-argv-\(UUID().uuidString).txt")
        let stub = try makeStub("""
        printf '%s' "$2" > "\(capture.path)"
        cat <<'CHORUS_EOF'
        \(Self.validAdviceJSON)
        CHORUS_EOF
        """)
        let codex = KnownCLIEngine.catalog.first { $0.id == "codex" }!
        let provider = CLIAdviceProvider(engine: codex, executable: stub)
        let advice = try await provider.advise(photoPaths: ["/tmp/desk.jpg"], context: context)
        #expect(advice.offsets.count == 1)
        let argvPrompt = try String(contentsOf: capture, encoding: .utf8)
        #expect(argvPrompt.contains("桌面照片：/tmp/desk.jpg"))
        try? FileManager.default.removeItem(at: capture)
    }
}
