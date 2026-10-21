import ChorusCore
import Foundation
import Testing
@testable import Chorus

@Suite("AI memory marker")
struct AIMemoryMarkerTests {
    @Test("marker 逐字符合 2.6.3，drop key 位於 root")
    func exactContents() {
        #expect(AIMemoryMarker.contents(project: "chorus-advisor") ==
            "workspace = \"app-agents\"\nproject = \"chorus-advisor\"\ndrop_subagent_captures = \"true\"\n\n[profile]\ncontribute = false\nconsume = false\n")
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-marker-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func stub(in directory: URL, script: String) throws -> URL {
        let url = directory.appendingPathComponent("stub")
        try ("#!/bin/sh\n" + script).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test("三個正式 provider 啟動瞬間已在獨立 cwd 寫入正確 marker 與 origin",
          arguments: ["chorus-advisor", "chorus-audio-advisor", "chorus-translate"])
    func providersMarkBeforeLaunch(project: String) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let capture = directory.appendingPathComponent("capture")
        let executable = try stub(in: directory, script: """
        test -f .ai-memory.toml || exit 71
        test "$FI_AGENT_ORIGIN" = chorus || exit 72
        test "$PWD" != "$TMPDIR" || exit 73
        cat .ai-memory.toml > '\(capture.path)'
        printf '\\n%s' "$PWD" >> '\(capture.path)'
        printf '%s' '{"sceneSummary":"test","offsets":[],"warnings":[],"summary":"test","effects":[],"translations":[]}'
        """)
        let engine = try #require(KnownCLIEngine.catalog.first { $0.id == "codex" })
        switch project {
        case "chorus-advisor":
            // nil 模擬 LightingAdvisor.makeSandbox 失敗；仍須另建獨立 cwd。
            _ = try await CLIAdviceProvider(engine: engine, executable: executable).advise(
                photos: [], context: AdviceContext(displays: [], curve: AmbientCurve()), sandbox: nil
            )
        case "chorus-audio-advisor":
            _ = try await CLIAudioAdviceProvider(engine: engine, executable: executable).advise(
                context: AudioTuningContext(targetKind: "app", targetName: "test", targetDetail: "",
                                            request: "", bandFrequencies: [], availableEffects: []),
                sandbox: directory
            )
        default:
            _ = try await CLIUITranslationBatchRunner(engine: engine, executable: executable)
                .translate([], targetLanguage: "ja")
        }
        let captured = try String(contentsOf: capture, encoding: .utf8)
        let prefix = AIMemoryMarker.contents(project: project) + "\n"
        #expect(captured.hasPrefix(prefix))
        let cwd = String(captured.dropFirst(prefix.count))
        if project == "chorus-audio-advisor" {
            #expect(URL(fileURLWithPath: cwd).resolvingSymlinksInPath() == directory.resolvingSymlinksInPath())
        } else {
            #expect(cwd.contains("/\(project)-"))
            #expect(!FileManager.default.fileExists(atPath: cwd)) // 自建 cwd 已清理
        }
    }

    @Test("marker 寫入失敗走既有無法啟動錯誤，子行程不執行")
    func failedWriteDoesNotLaunch() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 目錄佔住 marker 檔名，避免 chmod 測試在不同權限下不可靠。
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(".ai-memory.toml"), withIntermediateDirectories: true
        )
        let launched = directory.appendingPathComponent("launched")
        let executable = try stub(in: directory, script: "touch '\(launched.path)'")
        let engine = try #require(KnownCLIEngine.catalog.first { $0.id == "codex" })
        do {
            _ = try await CLIAdviceProvider(engine: engine, executable: executable).advise(
                photos: [], context: AdviceContext(displays: [], curve: AmbientCurve()), sandbox: directory
            )
            Issue.record("預期無法啟動")
        } catch let error as AdviceError {
            guard case let .engineNotFound(engineID) = error else {
                Issue.record("預期 engineNotFound，得到 \(error)")
                return
            }
            #expect(engineID == engine.id)
        }
        #expect(!FileManager.default.fileExists(atPath: launched.path))
    }

    @Test("origin 加入後保留 runner 既有環境及引擎環境")
    func preservesEnvironment() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = try await CLIProcessRunner.run(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "test -f .ai-memory.toml || exit 1; printf '%s\\n' \"$FI_AGENT_ORIGIN\" \"$CUSTOM\" \"$HOME\" \"$PATH\""],
            stdin: nil, timeout: .seconds(5), extraEnvironment: ["CUSTOM": "kept"],
            session: .init(directory: directory, project: "chorus-advisor")
        )
        #expect(output.status == 0)
        let values = output.stdout.components(separatedBy: "\n")
        try #require(values.count >= 4)
        #expect(values[0] == "chorus")
        #expect(values[1] == "kept")
        #expect(values[2] == CLIProcessRunner.whitelistedEnvironment(executableDirectory: "/bin")["HOME"])
        #expect(values[3] == CLIProcessRunner.whitelistedEnvironment(executableDirectory: "/bin")["PATH"])
    }
}
