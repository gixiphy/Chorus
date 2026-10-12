import Foundation

/// Test fixtures for desktop agent process matching (Codex.app / Claude desktop).
/// Schema & rules references: `docs/spec.md` §4.4, `docs/research/chorus-keepawake.md` §6.2,
/// and `docs/research/keepawake-open-questions.md` (R01 Q6-Q7).
/// Note: Claude Team ID Q6L2SF6YDW is UNCONFIRMED per R01 Q6 and spec §4.4; Claude desktop fixtures are marked unconfirmed.
enum DesktopAgentFixtures {
    struct Case: Sendable {
        let executablePath: String?
        let argv: [String]
        let expected: String?
    }

    // source: documented - spec §4.4 and CodexBar rules for Codex.app embedded app-server
    static let codexAppServer = Case(
        executablePath: "/Applications/Codex.app/Contents/Resources/codex",
        argv: ["/Applications/Codex.app/Contents/Resources/codex", "app-server"],
        expected: "codexApp"
    )

    // source: documented - spec §4.4 and CodexBar rules for ChatGPT.app embedded codex app-server
    static let chatGPTAppServer = Case(
        executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex",
        argv: ["/Applications/ChatGPT.app/Contents/Resources/codex", "app-server"],
        expected: "codexApp"
    )

    // source: documented - spec §4.4 standalone CLI codex does not count as desktop App
    static let cliCodex = Case(
        executablePath: "/opt/homebrew/bin/codex",
        argv: ["codex"],
        expected: nil
    )

    // source: documented - spec §4.4 exclusion of --version and --help invocations
    static let codexVersion = Case(
        executablePath: "/Applications/Codex.app/Contents/Resources/codex",
        argv: ["codex", "--version"],
        expected: nil
    )

    // source: documented - spec §4.4 exclusion of --help invocations even with app-server
    static let codexAppServerHelp = Case(
        executablePath: "/Applications/Codex.app/Contents/Resources/codex",
        argv: ["codex", "app-server", "--help"],
        expected: nil
    )

    // source: assumed - untrusted location outside /Applications or ~/Applications must not match
    static let fakeCodexApp = Case(
        executablePath: "/tmp/fake/Codex.app/Contents/Resources/codex",
        argv: ["/tmp/fake/Codex.app/Contents/Resources/codex", "app-server"],
        expected: nil
    )

    // source: assumed - Claude desktop internal binary (UNCONFIRMED: Claude Team ID Q6L2SF6YDW and exact app structure per R01 Q6)
    static let claudeDesktop = Case(
        executablePath: "/Users/test/Library/Application Support/Claude/claude-code/0.2.29/claude",
        argv: ["/Users/test/Library/Application Support/Claude/claude-code/0.2.29/claude"],
        expected: "claudeApp"
    )

    // source: documented - spec §4.4 exclusion of --version for claude
    static let claudeVersion = Case(
        executablePath: "/Users/test/Library/Application Support/Claude/claude-code/0.2.29/claude",
        argv: ["claude", "--version"],
        expected: nil
    )

    // source: documented - spec §4.4 exclusion of claude-code-acp protocol process
    static let claudeCodeAcp = Case(
        executablePath: "/Users/test/Library/Application Support/Claude/claude-code/0.2.29/claude",
        argv: ["claude", "claude-code-acp"],
        expected: nil
    )

    // source: assumed - Claude desktop process wrapped by disclaimer helper (UNCONFIRMED per R01 Q6 / research §6.2)
    static let claudeWithDisclaimer = Case(
        executablePath: "/Users/test/Library/Application Support/Claude/claude-code/0.2.29/claude",
        argv: ["disclaimer", "/Users/test/Library/Application Support/Claude/claude-code/0.2.29/claude"],
        expected: "claudeApp"
    )

    /// Table of all test cases: `(executablePath: String?, argv: [String], expected: String?)`
    static let allCases: [(executablePath: String?, argv: [String], expected: String?)] = [
        (codexAppServer.executablePath, codexAppServer.argv, codexAppServer.expected),
        (chatGPTAppServer.executablePath, chatGPTAppServer.argv, chatGPTAppServer.expected),
        (cliCodex.executablePath, cliCodex.argv, cliCodex.expected),
        (codexVersion.executablePath, codexVersion.argv, codexVersion.expected),
        (codexAppServerHelp.executablePath, codexAppServerHelp.argv, codexAppServerHelp.expected),
        (fakeCodexApp.executablePath, fakeCodexApp.argv, fakeCodexApp.expected),
        (claudeDesktop.executablePath, claudeDesktop.argv, claudeDesktop.expected),
        (claudeVersion.executablePath, claudeVersion.argv, claudeVersion.expected),
        (claudeCodeAcp.executablePath, claudeCodeAcp.argv, claudeCodeAcp.expected),
        (claudeWithDisclaimer.executablePath, claudeWithDisclaimer.argv, claudeWithDisclaimer.expected),
    ]
}
