import Foundation

/// 桌面 App（Codex／Claude）argv 判定規則（spec §4.4；R01 Q6–Q7）。
///
/// 純函式：不執行行程、不讀檔案、不做驗簽。

public enum DesktopAgentKind: String, Sendable, Equatable, Codable, CaseIterable {
    case codexApp
    case claudeApp
}

public enum DesktopAgentMatcher {
    /// R01／CodexBar：Codex／ChatGPT 桌面版 Team ID（已確認）。
    public static let codexTeamID = "2DC432GLL2"

    /// R01 Q6：Claude 桌面 Team ID **未確認**。確認前為 nil（不驗簽）。
    /// 搜尋摘要候選 `Q6L2SF6YDW` 見 `claudeTeamIDUnconfirmedCandidate`；Fi A4 停用 Claude 桌面來源。
    public static let claudeTeamID: String? = nil

    /// R01 Q6 未確認候選（不得當作已驗證 Team ID）。
    public static let claudeTeamIDUnconfirmedCandidate = "Q6L2SF6YDW"

    /// Fi A4：Claude Team ID 未確認時**停用**桌面 Claude 來源（只靠既有 log／行程層）。
    /// C07 必須檢查此旗標；matcher 仍可分類路徑以便 fixtures／未來啟用。
    public static let claudeDesktopSourceEnabled = false

    /// Claude transcript 根（相對 `$HOME`）。R01 Q7 未確認桌面另有路徑；暫用既有 `.claude/projects`。
    public static let claudeTranscriptRoots: [String] = [".claude/projects"]

    /// Codex rollout 檔名開頭（與 `AgentRegistry` codex 來源一致）。
    public static let codexRolloutPrefix = "rollout-"

    /// argv／路徑規則：回傳命中的桌面種類；不符合回 nil。
    public static func classify(executablePath: String?, arguments: [String]) -> DesktopAgentKind? {
        if matchesCodexApp(executablePath: executablePath, arguments: arguments) {
            return .codexApp
        }
        if matchesClaudeApp(executablePath: executablePath, arguments: arguments) {
            return .claudeApp
        }
        return nil
    }

    // MARK: - Codex

    /// argv 含 `app-server`，basename 為 `codex`，不含 `--help`／`--version`，
    /// 且執行檔在信任的 `/Applications` 或 `~/Applications` 的 Codex／ChatGPT.app 內。
    public static func matchesCodexApp(executablePath: String?, arguments: [String]) -> Bool {
        guard !argumentsContainHelpOrVersion(arguments) else { return false }
        guard argumentsContainToken(arguments, token: "app-server") else { return false }
        guard let path = executablePath, isTrustedCodexExecutable(path) else { return false }
        let base = (path as NSString).lastPathComponent
        guard base == "codex" || argumentsContainBasename(arguments, name: "codex") else {
            return false
        }
        return true
    }

    public static func isTrustedCodexExecutable(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        let suffixes = [
            "/Codex.app/Contents/Resources/codex",
            "/ChatGPT.app/Contents/Resources/codex",
        ]
        guard suffixes.contains(where: { standardized.hasSuffix($0) }) else { return false }
        return isUnderApplicationsTree(standardized)
    }

    // MARK: - Claude

    /// 任一 argv 含 `Application Support/Claude/claude-code/`，basename 為 `claude`，
    /// 且不含 `--version`／`--help`／`claude-code-acp`。
    public static func matchesClaudeApp(executablePath: String?, arguments: [String]) -> Bool {
        guard !argumentsContainHelpOrVersion(arguments) else { return false }
        guard !argumentsContainToken(arguments, token: "claude-code-acp") else { return false }

        let marker = "Application Support/Claude/claude-code/"
        let candidates = ([executablePath].compactMap { $0 } + arguments)
        guard candidates.contains(where: { $0.contains(marker) }) else { return false }

        // basename 必須是 claude（執行檔路徑或 argv 中帶路徑的那一項）。
        let hasClaudeBase = candidates.contains { candidate in
            guard candidate.contains(marker) else { return false }
            return (candidate as NSString).lastPathComponent == "claude"
        }
        return hasClaudeBase || argumentsContainBasename(arguments, name: "claude")
    }

    // MARK: - Shared helpers

    public static func argumentsContainHelpOrVersion(_ arguments: [String]) -> Bool {
        arguments.contains { token in
            token == "--help" || token == "--version"
                || token.hasPrefix("--help=") || token.hasPrefix("--version=")
        }
    }

    private static func argumentsContainToken(_ arguments: [String], token: String) -> Bool {
        arguments.contains(token)
    }

    private static func argumentsContainBasename(_ arguments: [String], name: String) -> Bool {
        arguments.contains { argument in
            (argument as NSString).lastPathComponent == name
        }
    }

    /// `/Applications/...` 或 `/Users/<name>/Applications/...`。
    public static func isUnderApplicationsTree(_ path: String) -> Bool {
        if path.hasPrefix("/Applications/") { return true }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // Users/<name>/Applications/...
        if parts.count >= 3, parts[0] == "Users", parts[2] == "Applications" {
            return true
        }
        return false
    }
}
