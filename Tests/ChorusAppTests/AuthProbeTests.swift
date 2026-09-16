import Foundation
import Testing
@testable import Chorus

/// 登入狀態探測（Part 2 §8）。三種 probe 都只讀狀態，所以測得起來：
/// 憑證檔用臨時家目錄、環境變數用注入的字典、指令用 `/usr/bin/true`／`false`。
@Suite("引擎登入狀態探測")
struct AuthProbeTests {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-auth-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    @Test("credentialFile：檔案存在＝已登入")
    func credentialFilePresent() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let credential = home.appendingPathComponent(".grok/auth.json")
        try FileManager.default.createDirectory(
            at: credential.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("{}".utf8).write(to: credential)

        let state = AdviceEngineRegistry.evaluateAuth(
            .credentialFile(path: ".grok/auth.json"),
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            home: home.path
        )
        #expect(state == .loggedIn)
    }

    @Test("credentialFile：檔案不存在＝未登入")
    func credentialFileMissing() throws {
        let home = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let state = AdviceEngineRegistry.evaluateAuth(
            .credentialFile(path: ".grok/auth.json"),
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            home: home.path
        )
        #expect(state == .notLoggedIn)
    }

    @Test("environmentKey：任一變數存在且非空＝已登入")
    func environmentKeyPresent() {
        let state = AdviceEngineRegistry.evaluateAuth(
            .environmentKey(names: ["MISSING_KEY", "AMP_API_KEY"]),
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            environment: ["AMP_API_KEY": "sk-test"]
        )
        #expect(state == .loggedIn)
    }

    @Test("environmentKey：變數缺席或空字串都算未登入")
    func environmentKeyMissing() {
        #expect(AdviceEngineRegistry.evaluateAuth(
            .environmentKey(names: ["AMP_API_KEY"]),
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            environment: [:]
        ) == .notLoggedIn)
        // 空字串是「export 了但沒填」，不該當成已登入
        #expect(AdviceEngineRegistry.evaluateAuth(
            .environmentKey(names: ["AMP_API_KEY"]),
            executable: URL(fileURLWithPath: "/usr/bin/true"),
            environment: ["AMP_API_KEY": ""]
        ) == .notLoggedIn)
    }

    @Test("command：退出碼 0＝已登入")
    func commandSucceeds() {
        let state = AdviceEngineRegistry.evaluateAuth(
            .command(arguments: []),
            executable: URL(fileURLWithPath: "/usr/bin/true")
        )
        #expect(state == .loggedIn)
    }

    @Test("command：非零退出＝未登入")
    func commandFails() {
        let state = AdviceEngineRegistry.evaluateAuth(
            .command(arguments: []),
            executable: URL(fileURLWithPath: "/usr/bin/false")
        )
        #expect(state == .notLoggedIn)
    }

    @Test("command：跑不起來＝未知（探測失敗不該變成「不能用這家」）")
    func commandUnrunnable() {
        let state = AdviceEngineRegistry.evaluateAuth(
            .command(arguments: []),
            executable: URL(fileURLWithPath: "/nonexistent/chorus-not-a-cli")
        )
        #expect(state == .unknown)
    }

    @Test("執行探測：跑得起來＋退出碼 0 取第一行當版本")
    func probeReadsFirstLine() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = directory.appendingPathComponent("stub")
        try "#!/bin/sh\nprintf '1.2.3\\nextra line\\n'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        #expect(AdviceEngineRegistry.probeExecutable(at: stub) == .ready(version: "1.2.3"))
    }

    @Test("執行探測：不認 --version 但跑得起來＝可用、沒有版本")
    func probeWithoutVersionFlag() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chorus-probe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let stub = directory.appendingPathComponent("stub")
        try "#!/bin/sh\necho 'unknown flag' >&2\nexit 2\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        #expect(AdviceEngineRegistry.probeExecutable(at: stub) == .ready(version: nil))
    }

    @Test("執行探測：跑不起來＝failed（半裝好的 CLI 不該列進可用清單）")
    func probeFailsForMissingExecutable() {
        let missing = URL(fileURLWithPath: "/nonexistent/chorus-not-a-cli")
        #expect(AdviceEngineRegistry.probeExecutable(at: missing) == .failed)
    }
}
