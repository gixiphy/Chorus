import Foundation
import Testing
@testable import ChorusCore

@Suite("AgentProcessMatcher")
struct AgentProcessMatcherTests {
    private let matcher = AgentProcessMatcher()

    private func normalize(_ value: String, stripScriptExtension: Bool = false) -> String {
        AgentProcessMatcher.normalize(value, stripScriptExtension: stripScriptExtension)
    }

    // MARK: - normalize

    @Test("normalize takes the basename, lowercases, and unwraps quotes")
    func normalizeBasics() {
        #expect(normalize("/opt/homebrew/bin/claude") == "claude")
        #expect(normalize("  Cursor-Agent  ") == "cursor-agent")
        #expect(normalize("\"C:\\Program Files\\codex.exe\"", stripScriptExtension: true) == "codex")
        #expect(normalize("'/usr/bin/goose'") == "goose")
        #expect(normalize("") == "")
    }

    @Test("Script extensions only come off when asked")
    func normalizeScriptExtensions() {
        #expect(normalize("claude.cmd") == "claude.cmd")
        for wrapper in ["claude.exe", "claude.cmd", "claude.bat", "claude.ps1"] {
            #expect(normalize(wrapper, stripScriptExtension: true) == "claude")
        }
        // entrypoint 的 .js 不是包裝腳本，不能砍——砍了會把 cli.js 當成 agent 名 cli。
        #expect(normalize("cli.js", stripScriptExtension: true) == "cli.js")
    }

    // MARK: - 行程名

    @Test("Registered names and aliases match")
    func exactNames() {
        #expect(matcher.match(processName: "claude")?.agentID == "claude")
        #expect(matcher.match(processName: "/opt/homebrew/bin/claude")?.engine == "Claude Code")
        #expect(matcher.match(processName: "openclaude")?.agentID == "openclaude")
        #expect(matcher.match(processName: "kiro-cli")?.agentID == "kiro")
        #expect(matcher.match(processName: "command-code")?.agentID == "command-code")
        #expect(matcher.match(processName: "cn")?.agentID == "continue")
        #expect(matcher.match(processName: "mistral-vibe")?.agentID == "mistral-vibe")
        #expect(matcher.match(processName: "vibe")?.agentID == "mistral-vibe")
        #expect(matcher.match(processName: "acli")?.agentID == "rovo")
        #expect(matcher.match(processName: "Cursor-Agent")?.agentID == "cursor")
    }

    @Test("Packaged binaries match by prefix, lookalikes do not")
    func prefixes() {
        #expect(matcher.match(processName: "codex-aarch64-apple-darwin")?.agentID == "codex")
        // p_comm 只有 16 個字。
        #expect(matcher.match(processName: "codex-aarch64-ap")?.agentID == "codex")
        #expect(matcher.match(processName: "grok-x86_64-unknown-linux")?.agentID == "grok")
        #expect(matcher.match(processName: "codexbar") == nil)
        #expect(matcher.match(processName: "codexplorer") == nil)
        #expect(matcher.match(processName: "claudius") == nil)
        #expect(matcher.match(processName: "node") == nil)
    }

    @Test("isCandidate keeps the cheap first pass wide but not open")
    func candidates() {
        #expect(matcher.isCandidate(comm: "claude"))
        #expect(matcher.isCandidate(comm: "node"))
        #expect(matcher.isCandidate(comm: "python3.12"))
        #expect(matcher.isCandidate(comm: "python"))
        #expect(matcher.isCandidate(comm: "bun"))
        // 前綴也要進候選，否則打包過的 Codex 永遠不會被讀 argv。
        #expect(matcher.isCandidate(comm: "codex-aarch64-ap"))
        #expect(!matcher.isCandidate(comm: "Chrome"))
        #expect(!matcher.isCandidate(comm: "pythonista"))
        #expect(!matcher.isCandidate(comm: ""))

        // 自訂名超過 16 字時，只會在 p_comm 看到前 16 字。
        let long = AgentProcessMatcher(customProcessNames: ["my-very-long-agent-runner"])
        #expect(long.isCandidate(comm: "my-very-long-age"))
        #expect(long.match(processName: "my-very-long-age")?.agentID == "custom:my-very-long-agent-runner")
    }

    // MARK: - 直譯器 argv

    @Test("Node entrypoints resolve through package markers and patterns")
    func nodeEntrypoints() {
        #expect(matcher.match(arguments: [
            "node", "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
        ])?.agentID == "claude")
        // `--import <loader>` 要跳過兩個 token 才看得到真正的 entrypoint。
        #expect(matcher.match(arguments: [
            "node", "--import", "/tmp/instrument.mjs",
            "/Users/x/node_modules/@openai/codex/bin/codex.js",
        ])?.agentID == "codex")
        #expect(matcher.match(arguments: [
            "node", "/Users/x/.local/share/cursor-agent/versions/2026.09.1/index.js",
        ])?.agentID == "cursor")
        #expect(matcher.match(arguments: [
            "node", "/x/node_modules/@mariozechner/pi-coding-agent/dist/cli.js",
        ])?.agentID == "pi")
        #expect(matcher.match(arguments: [
            "node", "/x/node_modules/@earendil-works/pi-coding-agent/dist/cli.js",
        ])?.agentID == "pi")
        #expect(matcher.match(arguments: [
            "node", "/x/node_modules/prime-agent/dist/bundle/cli.js",
        ])?.agentID == "prime-agent")
        #expect(matcher.match(arguments: ["node", "/x/node_modules/@some/other/cli.js"]) == nil)
    }

    @Test("Inline code and prompt text never count as an entrypoint")
    func rejectsInlineCode() {
        #expect(matcher.match(arguments: ["node", "-e", "claude"]) == nil)
        #expect(matcher.match(arguments: ["node", "--eval", "require('codex')"]) == nil)
        #expect(matcher.match(arguments: ["node", "-p", "goose"]) == nil)
        #expect(matcher.match(arguments: ["node", "--check", "aider.py"]) == nil)
        // 沒有路徑分隔也沒有副檔名的 token 不是可執行檔。
        #expect(matcher.match(arguments: ["node", "claude"]) == nil)
        // entrypoint 認不出來時，後面 token 裡的 agent 名不算。
        #expect(matcher.match(arguments: ["node", "/tmp/tool.js", "goose", "claude"]) == nil)
        #expect(matcher.match(arguments: ["node"]) == nil)
        #expect(matcher.match(arguments: []) == nil)
    }

    @Test("Python modules and installed scripts match, loose scripts do not")
    func pythonEntrypoints() {
        #expect(matcher.match(arguments: ["python3", "-m", "aider.main"])?.agentID == "aider")
        #expect(matcher.match(arguments: ["python3.12", "-m", "aider"])?.agentID == "aider")
        #expect(matcher.match(arguments: ["python3", "-m", "http.server"]) == nil)
        #expect(matcher.match(arguments: ["python3", "/venv/bin/goose"])?.agentID == "goose")
        #expect(matcher.match(arguments: [
            "python", "/opt/venv/lib/python3.12/site-packages/hermes/__main__.py",
        ]) == nil)
        // /bin/、/scripts/、/site-packages/ 以外的腳本一律不認。
        #expect(matcher.match(arguments: ["python3", "/tmp/goose.py"]) == nil)
        #expect(matcher.match(arguments: ["python3", "-c", "import goose"]) == nil)
    }

    @Test("argv[0] wins before any entrypoint work")
    func argvZeroFirst() {
        #expect(matcher.match(arguments: ["claude", "-p", "hello"])?.agentID == "claude")
        // headless 的一次性 run 一樣要讓機器醒著，不濾掉。
        #expect(matcher.match(arguments: ["/opt/homebrew/bin/claude", "-p", "batch job"])?.engine == "Claude Code")
        #expect(matcher.match(arguments: ["codex-aarch64-ap", "exec"])?.agentID == "codex")
    }

    // MARK: - tokenize

    @Test("tokenize honours quotes and backslash escapes")
    func tokenizeQuoting() {
        #expect(AgentProcessMatcher.tokenize("node  /tmp/cli.js  --flag") == ["node", "/tmp/cli.js", "--flag"])
        #expect(AgentProcessMatcher.tokenize("node \"/Users/a b/cli.js\"") == ["node", "/Users/a b/cli.js"])
        #expect(AgentProcessMatcher.tokenize("claude -p 'fix the \"bug\"'") == ["claude", "-p", "fix the \"bug\""])
        #expect(AgentProcessMatcher.tokenize("node /tmp/a\\ b.js") == ["node", "/tmp/a b.js"])
        #expect(AgentProcessMatcher.tokenize("claude -p ''") == ["claude", "-p", ""])
        #expect(AgentProcessMatcher.tokenize("   ") == [])
    }

    @Test("A whole command line matches like its argv")
    func commandLineMatching() {
        #expect(matcher.match(commandLine: "/opt/homebrew/bin/claude --resume")?.agentID == "claude")
        #expect(matcher.match(
            commandLine: "node \"/Users/a b/node_modules/@openai/codex/bin/codex.js\" exec"
        )?.agentID == "codex")
        #expect(matcher.match(commandLine: "/usr/bin/ssh host") == nil)
    }

    // MARK: - 自訂名

    @Test("parseCustomNames normalises, dedupes and refuses interpreters")
    func customNameParsing() {
        #expect(AgentProcessMatcher.parseCustomNames("aider, Goose ,, goose ") == ["aider", "goose"])
        #expect(AgentProcessMatcher.parseCustomNames("/usr/local/bin/my-agent") == ["my-agent"])
        #expect(AgentProcessMatcher.parseCustomNames("") == [])
        // 收下直譯器等於「只要有人在跑 node 就別睡」。
        #expect(AgentProcessMatcher.parseCustomNames("node, python3, python3.12, bun, deno") == [])
        #expect(AgentProcessMatcher.parseCustomNames("yes, node") == ["yes"])
    }

    @Test("Custom names match exactly and never shadow the registry")
    func customNames() {
        let custom = AgentProcessMatcher(customProcessNames: ["yes", "claude"])
        let match = custom.match(processName: "yes")
        #expect(match?.agentID == "custom:yes")
        #expect(match?.engine == "yes")
        #expect(custom.isCandidate(comm: "yes"))
        // 自訂名不可覆蓋註冊表。
        #expect(custom.match(processName: "claude")?.agentID == "claude")
        #expect(custom.match(processName: "claude")?.engine == "Claude Code")
        // 自訂名只吃精確比對，不做前綴。
        #expect(custom.match(processName: "yesman") == nil)
        #expect(matcher.match(processName: "yes") == nil)
    }

    @Test("Two matchers are equal when the registry and custom names agree")
    func equality() {
        #expect(AgentProcessMatcher() == AgentProcessMatcher())
        #expect(AgentProcessMatcher(customProcessNames: ["yes"]) != AgentProcessMatcher())
        #expect(AgentProcessMatcher(customProcessNames: ["yes"]) == AgentProcessMatcher(customProcessNames: ["yes"]))
    }
}
