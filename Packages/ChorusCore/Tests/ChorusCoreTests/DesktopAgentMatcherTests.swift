import Foundation
import Testing
@testable import ChorusCore

@Suite("DesktopAgentMatcher")
struct DesktopAgentMatcherTests {
    @Test("V-C04-2 every DesktopAgentFixtures case matches expected", arguments: DesktopAgentFixtures.allCases)
    func fixtureTable(
        _ fixture: (executablePath: String?, argv: [String], expected: String?)
    ) {
        let kind = DesktopAgentMatcher.classify(
            executablePath: fixture.executablePath,
            arguments: fixture.argv
        )
        #expect(kind?.rawValue == fixture.expected)
    }

    @Test("Codex Team ID confirmed; Claude Team ID nil / source disabled (Fi A4)")
    func teamIDPolicy() {
        #expect(DesktopAgentMatcher.codexTeamID == "2DC432GLL2")
        #expect(DesktopAgentMatcher.claudeTeamID == nil)
        #expect(DesktopAgentMatcher.claudeDesktopSourceEnabled == false)
        #expect(DesktopAgentMatcher.claudeTeamIDUnconfirmedCandidate == "Q6L2SF6YDW")
    }

    @Test("~/Applications Codex.app is trusted; /tmp is not")
    func applicationsTree() {
        let homeCodex = "/Users/test/Applications/Codex.app/Contents/Resources/codex"
        #expect(DesktopAgentMatcher.isTrustedCodexExecutable(homeCodex))
        #expect(
            DesktopAgentMatcher.classify(
                executablePath: homeCodex,
                arguments: [homeCodex, "app-server"]
            ) == .codexApp
        )
        #expect(!DesktopAgentMatcher.isTrustedCodexExecutable(
            "/tmp/fake/Codex.app/Contents/Resources/codex"
        ))
    }

    @Test("--help / --version exclude even with app-server")
    func helpVersionExcluded() {
        #expect(
            DesktopAgentMatcher.classify(
                executablePath: "/Applications/Codex.app/Contents/Resources/codex",
                arguments: ["codex", "app-server", "--help"]
            ) == nil
        )
        #expect(
            DesktopAgentMatcher.classify(
                executablePath: "/Applications/Codex.app/Contents/Resources/codex",
                arguments: ["codex", "--version"]
            ) == nil
        )
    }

    @Test("claude-code-acp excluded")
    func claudeAcpExcluded() {
        let path = "/Users/test/Library/Application Support/Claude/claude-code/0.2.29/claude"
        #expect(
            DesktopAgentMatcher.classify(
                executablePath: path,
                arguments: ["claude", "claude-code-acp"]
            ) == nil
        )
    }

    @Test("matcher still classifies Claude paths while source remains disabled")
    func claudePathClassifiedButSourceDisabled() {
        let path = "/Users/test/Library/Application Support/Claude/claude-code/0.2.29/claude"
        #expect(
            DesktopAgentMatcher.classify(executablePath: path, arguments: [path]) == .claudeApp
        )
        #expect(DesktopAgentMatcher.claudeDesktopSourceEnabled == false)
    }
}
