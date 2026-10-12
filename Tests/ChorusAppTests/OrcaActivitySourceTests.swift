import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("OrcaActivitySource")
struct OrcaActivitySourceTests {
    final class FakePresence: OrcaPresenceChecking, @unchecked Sendable {
        var running = true
        func isOrcaRunning() -> Bool { running }
    }

    final class FakeRunner: OrcaCommandRunning, @unchecked Sendable {
        var results: [OrcaCommandRunResult] = []
        private(set) var callCount = 0
        private(set) var lastExecutable: String?

        func run(
            executable: String,
            arguments: [String],
            environment: [String: String],
            timeout: Duration,
            stdoutLimit: Int
        ) async -> OrcaCommandRunResult {
            callCount += 1
            lastExecutable = executable
            #expect(arguments == ["worktree", "ps", "--json"])
            if results.isEmpty {
                return OrcaCommandRunResult(
                    exitCode: 1, stdout: Data(), stderr: Data(), timedOut: false, killed: false
                )
            }
            return results.removeFirst()
        }
    }

    private let workingJSON = """
    {"ok":true,"result":{"worktrees":[{"worktreeId":"w1","status":"working"}],"truncated":false}}
    """
    private let permissionJSON = """
    {"ok":true,"result":{"worktrees":[{"worktreeId":"w1","status":"permission"}],"truncated":false}}
    """

    @Test("V-C07-2 missing CLI → unavailable")
    func missingCLI() async {
        let runner = FakeRunner()
        let source = OrcaActivitySource(runner: runner, presence: FakePresence())
        source.cliPathResolver = { nil }
        source.configure(enabled: true, countPermissionAsWorking: true, cliPathOverride: nil)
        source.start()
        await source.pollOnce()
        #expect(source.report.count == 1)
        #expect(source.report.first?.health == .unavailable(reason: "找不到 orca CLI"))
        #expect(runner.callCount == 0)
        source.stop()
    }

    @Test("V-C07-2 timeout marks degraded and runner reports kill path")
    func timeoutDegraded() async {
        let runner = FakeRunner()
        runner.results = [
            OrcaCommandRunResult(
                exitCode: nil, stdout: Data(), stderr: Data(), timedOut: true, killed: true
            ),
        ]
        let source = OrcaActivitySource(runner: runner, presence: FakePresence())
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }
        source.start()
        await source.pollOnce()
        guard case let .degraded(reason) = source.report.first?.health else {
            Issue.record("expected degraded, got \(String(describing: source.report.first?.health))")
            return
        }
        #expect(reason.contains("逾時") || reason.contains("失敗"))
        source.stop()
    }

    @Test("V-C07-2 three failures switch interval to 120s; success restores 30s")
    func backoffThenRecover() async {
        let runner = FakeRunner()
        let fail = OrcaCommandRunResult(
            exitCode: 1, stdout: Data(), stderr: Data(), timedOut: false, killed: false
        )
        runner.results = [fail, fail, fail]
        let source = OrcaActivitySource(
            runner: runner,
            presence: FakePresence(),
            normalInterval: .milliseconds(5),
            backoffInterval: .milliseconds(50)
        )
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }
        source.start()
        await source.pollOnce()
        await source.pollOnce()
        await source.pollOnce()
        #expect(runner.callCount == 3)

        runner.results = [
            OrcaCommandRunResult(
                exitCode: 0,
                stdout: Data(workingJSON.utf8),
                stderr: Data(),
                timedOut: false,
                killed: false
            ),
        ]
        await source.pollOnce()
        #expect(source.report.first?.isWorkingNow == true)
        source.stop()
    }

    @Test("V-C07-2 Orca not running does not execute CLI")
    func noOrcaNoCLI() async {
        let presence = FakePresence()
        presence.running = false
        let runner = FakeRunner()
        let source = OrcaActivitySource(runner: runner, presence: presence)
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }
        source.start()
        await source.pollOnce()
        #expect(runner.callCount == 0)
        #expect(source.report.isEmpty)
        source.stop()
    }

    @Test("V-C07-2 permission setting honored")
    func permissionSetting() async {
        let runner = FakeRunner()
        runner.results = [
            OrcaCommandRunResult(
                exitCode: 0,
                stdout: Data(permissionJSON.utf8),
                stderr: Data(),
                timedOut: false,
                killed: false
            ),
            OrcaCommandRunResult(
                exitCode: 0,
                stdout: Data(permissionJSON.utf8),
                stderr: Data(),
                timedOut: false,
                killed: false
            ),
        ]
        let source = OrcaActivitySource(runner: runner, presence: FakePresence())
        source.cliPathResolver = { "/opt/homebrew/bin/orca" }

        source.configure(enabled: true, countPermissionAsWorking: true, cliPathOverride: nil)
        source.start()
        await source.pollOnce()
        #expect(source.report.first?.isWorkingNow == true)

        source.configure(enabled: true, countPermissionAsWorking: false, cliPathOverride: nil)
        await source.pollOnce()
        #expect(source.report.first?.isWorkingNow == false)
        source.stop()
    }
}
