import Foundation

/// 一支 agent 的 session log 根目錄（相對 `$HOME`，可被環境變數覆寫）。
///
/// 每一家 agent 自己決定 log 放哪、寫什麼副檔名、巢狀多深，所以這些全部資料化：
/// 加一家 agent 只要往 `AgentRegistry.all` 加一個 literal，掃描端不用改。
public struct AgentLogSource: Sendable, Hashable {
    /// 相對 `$HOME` 的路徑，不含前導 `~/`（例：`.claude/projects`）。
    public var defaultPath: String
    /// 覆寫用的環境變數名（例：`CLAUDE_CONFIG_DIR`、`XDG_DATA_HOME`）。nil ＝ 不可覆寫。
    public var overrideVariable: String?
    /// 接在變數值後面的相對路徑（例：`projects`）。變數本身就是根時填 `""`。
    public var overrideSubpath: String
    /// 收哪些副檔名（小寫 `pathExtension`）。**空集合 ＝ 全收**。
    ///
    /// SQLite 類的 agent 一律只收 `db-wal`：`.db` 要 checkpoint 才動，
    /// 而 `.db-shm` 的 mtime 會被任何唯讀輪詢的第三方工具碰到（本機實測
    /// CodexBar 一次碰了一整批），拿它當跡證等於把別人的輪詢當成 agent 在工作。
    public var extensions: Set<String>
    /// 這個根額外要跳過的目錄名。實際掃描時與 `AgentRegistry.defaultSkippedDirectories` 聯集。
    public var skippedDirectories: Set<String>
    /// 走訪深度上限（1 ＝ 只看根目錄直接底下）。
    public var maxDepth: Int
    /// 每個根最多走訪幾個項目。掃描是 30 秒一輪的常駐成本，寧可漏掉深處的舊檔。
    public var maxEntries: Int

    public init(
        defaultPath: String,
        overrideVariable: String? = nil,
        overrideSubpath: String = "",
        extensions: Set<String>,
        skippedDirectories: Set<String> = [],
        maxDepth: Int,
        maxEntries: Int = 3_000
    ) {
        self.defaultPath = defaultPath
        self.overrideVariable = overrideVariable
        self.overrideSubpath = overrideSubpath
        self.extensions = extensions
        self.skippedDirectories = skippedDirectories
        self.maxDepth = maxDepth
        self.maxEntries = maxEntries
    }

    /// 算出實際要掃的根。
    ///
    /// **變數存在且非空才覆寫**：shell 裡 `export CLAUDE_CONFIG_DIR=` 這種空值很常見，
    /// 照著它走會掃到 `$HOME` 或 `/projects`，比用預設路徑糟。
    public func resolveRoot(home: URL, environment: [String: String]) -> URL {
        if let overrideVariable,
           let value = environment[overrideVariable],
           !value.isEmpty {
            let base = URL(filePath: value, directoryHint: .isDirectory)
            return overrideSubpath.isEmpty ? base : base.appending(path: overrideSubpath)
        }
        if defaultPath.hasPrefix("/") { return URL(filePath: defaultPath, directoryHint: .isDirectory) }
        return home.appending(path: defaultPath)
    }

    /// 這個根收不收這個副檔名（空集合＝全收）。傳入值不必先轉小寫。
    public func accepts(pathExtension: String) -> Bool {
        extensions.isEmpty || extensions.contains(pathExtension.lowercased())
    }

    /// 掃描時真正要跳過的目錄名。
    public var effectiveSkippedDirectories: Set<String> {
        skippedDirectories.union(AgentRegistry.defaultSkippedDirectories)
    }
}

/// 一家 agent 的辨識規則與 log 位置。純資料。
public struct AgentDefinition: Sendable, Hashable, Identifiable {
    /// 穩定 id，與 Orca 的 agent id 對齊（AI 引擎目錄的 `KnownCLIEngine.id` 也用同一組）。
    public let id: String
    /// 顯示名（選單與設定頁直接秀這個字）。
    public let engine: String
    /// 行程名（小寫 basename，含別名）。
    public let processNames: Set<String>
    /// 行程名前綴。打包出來的 binary 會帶架構後綴（`codex-aarch64-apple-darwin`）。
    public let processPrefixes: [String]
    /// argv 裡出現就算命中的 npm 套件路徑片段（例：`node_modules/@openai/codex/`）。
    public let nodePackageMarkers: [String]
    /// node entrypoint 路徑樣式，`*` 配一段路徑（例：`cursor-agent/versions/*/index.js`）。
    public let nodeEntrypointPatterns: [String]
    /// `python -m <module>` 的模組名（取第一段比對）。
    public let pythonModules: Set<String>
    /// session log 根目錄，可以是空的——沒有全域 log 的 agent 只靠行程活動偵測。
    public let logSources: [AgentLogSource]

    public init(
        id: String,
        engine: String,
        processNames: Set<String>,
        processPrefixes: [String] = [],
        nodePackageMarkers: [String] = [],
        nodeEntrypointPatterns: [String] = [],
        pythonModules: Set<String> = [],
        logSources: [AgentLogSource] = []
    ) {
        self.id = id
        self.engine = engine
        self.processNames = processNames
        self.processPrefixes = processPrefixes
        self.nodePackageMarkers = nodePackageMarkers
        self.nodeEntrypointPatterns = nodeEntrypointPatterns
        self.pythonModules = pythonModules
        self.logSources = logSources
    }
}

/// 解析完環境變數之後、可以直接拿去掃的一個根。
public struct ResolvedAgentLogSource: Sendable, Hashable {
    public let engine: String
    public let root: URL
    public let source: AgentLogSource

    /// 測試與臨時根目錄用：jsonl、深度 6、預設跳過清單。
    public init(engine: String, root: URL) {
        self.init(
            engine: engine,
            root: root,
            source: AgentLogSource(
                defaultPath: root.path,
                extensions: ["jsonl"],
                skippedDirectories: AgentRegistry.defaultSkippedDirectories,
                maxDepth: 6
            )
        )
    }

    public init(engine: String, root: URL, source: AgentLogSource) {
        self.engine = engine
        self.root = root
        self.source = source
    }
}

/// 認得的 agent CLI 清單。
///
/// 這是「Agent 常亮」兩層偵測共用的唯一事實來源：第一層看 `logSources` 的 mtime，
/// 第二層看行程樹 CPU（辨識規則見 `AgentProcessMatcher`）。
/// 表上找不到的 CLI 由使用者在設定頁自己補行程名。
public enum AgentRegistry {
    /// 任何根都要跳過的目錄名。
    ///
    /// 兩類：一是**大而無跡證**的（`node_modules`、`versions`、`extensions`、`cache`、
    /// `canvases`、`mcps` 裡的 `.d.ts` 動輒上千個，走進去只是燒 IO）；
    /// 二是**會被非 agent 動作碰到 mtime** 的（`memory`、`todos`、`shell-snapshots`、
    /// `statsig`、`plugins`、`ide`、`debug`），拿它們當跡證會誤判成有人在工作。
    public static let defaultSkippedDirectories: Set<String> = [
        "node_modules", "versions", "extensions", "cache", ".git", "memory",
        "canvases", "mcps", "todos", "shell-snapshots", "statsig", "plugins",
        "ide", "debug", "bin",
    ]

    /// 直譯器行程名——這些行程的 argv 要再往下看 entrypoint 才知道是誰。
    public static let interpreterNames: Set<String> = ["node", "bun", "deno", "python", "python3"]

    public static func definition(id: String) -> AgentDefinition? { byID[id] }

    /// 展開所有 agent 的 log 根（環境變數已套用）。不存在的根由掃描端安靜略過。
    public static func resolvedLogSources(
        home: URL,
        environment: [String: String]
    ) -> [ResolvedAgentLogSource] {
        all.flatMap { definition in
            definition.logSources.map { source in
                ResolvedAgentLogSource(
                    engine: definition.engine,
                    root: source.resolveRoot(home: home, environment: environment),
                    source: source
                )
            }
        }
    }

    private static let byID: [String: AgentDefinition] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.id, $0) }
    )

    /// 加一家 agent ＝ 這裡加一個 literal ＋ `AgentRegistryTests` 的表格測試加一列。
    ///
    /// 「本機驗證」的路徑是這台 Mac 實際看到的；其餘照官方文件填，掃不到就是安靜略過，
    /// 錯的路徑不會有副作用（頂多這家只靠第二層偵測）。
    public static let all: [AgentDefinition] = [
        AgentDefinition(
            id: "claude",
            engine: "Claude Code",
            processNames: ["claude"],
            nodePackageMarkers: ["node_modules/@anthropic-ai/claude-code/"],
            logSources: [
                AgentLogSource(
                    defaultPath: ".claude/projects",
                    overrideVariable: "CLAUDE_CONFIG_DIR",
                    overrideSubpath: "projects",
                    extensions: ["jsonl"],
                    skippedDirectories: ["memory"],
                    maxDepth: 5
                )
            ]
        ),
        AgentDefinition(
            id: "openclaude",
            engine: "OpenClaude",
            processNames: ["openclaude"],
            logSources: [
                AgentLogSource(
                    defaultPath: ".openclaude/projects",
                    overrideVariable: "OPENCLAUDE_CONFIG_DIR",
                    overrideSubpath: "projects",
                    extensions: ["jsonl"],
                    maxDepth: 5
                ),
                AgentLogSource(
                    defaultPath: ".openclaude/bg-sessions",
                    overrideVariable: "OPENCLAUDE_CONFIG_DIR",
                    overrideSubpath: "bg-sessions",
                    extensions: ["jsonl"],
                    maxDepth: 5
                ),
            ]
        ),
        AgentDefinition(
            id: "codex",
            engine: "Codex",
            processNames: ["codex"],
            processPrefixes: ["codex-"],
            nodePackageMarkers: ["node_modules/@openai/codex/"],
            logSources: [
                AgentLogSource(
                    defaultPath: ".codex/sessions",
                    overrideVariable: "CODEX_HOME",
                    overrideSubpath: "sessions",
                    extensions: ["jsonl"],
                    maxDepth: 4
                )
            ]
        ),
        AgentDefinition(
            id: "gemini",
            engine: "Gemini CLI",
            processNames: ["gemini"],
            nodePackageMarkers: ["node_modules/@google/gemini-cli/"],
            logSources: [
                // `<hash>/chats/session-*.jsonl`；舊版是 .json。
                AgentLogSource(
                    defaultPath: ".gemini/tmp",
                    overrideVariable: "GEMINI_CLI_HOME",
                    overrideSubpath: ".gemini/tmp",
                    extensions: ["jsonl", "json"],
                    maxDepth: 3
                )
            ]
        ),
        AgentDefinition(
            id: "antigravity",
            engine: "Antigravity",
            processNames: ["agy"],
            logSources: [
                AgentLogSource(
                    defaultPath: ".gemini/antigravity-cli/conversations",
                    extensions: ["db-wal"],
                    maxDepth: 1
                )
            ]
        ),
        AgentDefinition(
            id: "cursor",
            engine: "Cursor CLI",
            processNames: ["cursor-agent"],
            nodeEntrypointPatterns: ["cursor-agent/versions/*/index.js"],
            logSources: [
                // `<hash>/agent-transcripts/*.jsonl` 與 `<hash>/terminals/*.txt`。
                AgentLogSource(
                    defaultPath: ".cursor/projects",
                    extensions: ["txt", "jsonl", "json"],
                    skippedDirectories: ["canvases", "mcps"],
                    maxDepth: 4
                )
            ]
        ),
        AgentDefinition(
            id: "copilot",
            engine: "GitHub Copilot CLI",
            processNames: ["copilot"],
            logSources: [
                AgentLogSource(
                    defaultPath: ".copilot/session-state",
                    overrideVariable: "COPILOT_HOME",
                    overrideSubpath: "session-state",
                    extensions: ["jsonl"],
                    maxDepth: 3
                )
            ]
        ),
        AgentDefinition(
            id: "opencode",
            engine: "OpenCode",
            processNames: ["opencode"],
            logSources: [
                // 新版是 `opencode.db-wal`，舊版寫 `storage/**.json`。
                AgentLogSource(
                    defaultPath: ".local/share/opencode",
                    overrideVariable: "XDG_DATA_HOME",
                    overrideSubpath: "opencode",
                    extensions: ["db-wal", "json"],
                    maxDepth: 3
                )
            ]
        ),
        AgentDefinition(
            id: "goose",
            engine: "Goose",
            processNames: ["goose"],
            logSources: [
                AgentLogSource(
                    defaultPath: ".local/share/goose/sessions",
                    overrideVariable: "XDG_DATA_HOME",
                    overrideSubpath: "goose/sessions",
                    extensions: ["db-wal", "jsonl"],
                    maxDepth: 2
                ),
                AgentLogSource(
                    defaultPath: "Library/Application Support/goose/sessions",
                    extensions: ["db-wal", "jsonl"],
                    maxDepth: 2
                ),
            ]
        ),
        AgentDefinition(
            id: "amp",
            engine: "Amp",
            processNames: ["amp"],
            logSources: [
                AgentLogSource(
                    defaultPath: ".local/share/amp/threads",
                    overrideVariable: "XDG_DATA_HOME",
                    overrideSubpath: "amp/threads",
                    extensions: ["json"],
                    maxDepth: 2
                ),
                AgentLogSource(
                    defaultPath: "Library/Application Support/amp/threads",
                    extensions: ["json"],
                    maxDepth: 2
                ),
            ]
        ),
        AgentDefinition(
            id: "droid",
            engine: "Factory Droid",
            processNames: ["droid"],
            logSources: [
                AgentLogSource(defaultPath: ".factory/sessions", extensions: ["jsonl"], maxDepth: 3)
            ]
        ),
        AgentDefinition(
            id: "kimi",
            engine: "Kimi Code",
            processNames: ["kimi", "kimi-code"],
            logSources: [
                // `<project>/<session>/wire.jsonl`；KIMI_SHARE_DIR 本身就是根。
                AgentLogSource(
                    defaultPath: ".kimi/sessions",
                    overrideVariable: "KIMI_SHARE_DIR",
                    extensions: ["jsonl"],
                    maxDepth: 3
                )
            ]
        ),
        AgentDefinition(
            id: "qwen",
            engine: "Qwen Code",
            processNames: ["qwen"],
            nodePackageMarkers: ["node_modules/@qwen-code/qwen-code/"],
            logSources: [
                AgentLogSource(defaultPath: ".qwen/projects", extensions: ["jsonl", "json"], maxDepth: 3),
                AgentLogSource(defaultPath: ".qwen/tmp", extensions: ["jsonl", "json"], maxDepth: 3),
            ]
        ),
        AgentDefinition(
            id: "pi",
            engine: "Pi",
            processNames: ["pi"],
            nodeEntrypointPatterns: [
                "node_modules/@earendil-works/pi-coding-agent/dist/cli.js",
                "node_modules/@mariozechner/pi-coding-agent/dist/cli.js",
            ],
            logSources: [
                AgentLogSource(
                    defaultPath: ".pi/agent/sessions",
                    overrideVariable: "PI_CODING_AGENT_DIR",
                    overrideSubpath: "sessions",
                    extensions: ["jsonl"],
                    maxDepth: 2
                )
            ]
        ),
        AgentDefinition(
            id: "omp",
            engine: "OMP",
            processNames: ["omp"],
            logSources: [
                AgentLogSource(defaultPath: ".omp/agent/sessions", extensions: ["jsonl"], maxDepth: 2)
            ]
        ),
        AgentDefinition(
            id: "prime-agent",
            engine: "Prime Agent",
            processNames: ["prime-agent"],
            nodeEntrypointPatterns: ["node_modules/prime-agent/dist/bundle/cli.js"],
            logSources: [
                AgentLogSource(defaultPath: ".prime/agent/sessions", extensions: ["jsonl"], maxDepth: 1)
            ]
        ),
        AgentDefinition(
            id: "kilo",
            engine: "Kilocode",
            processNames: ["kilo"],
            logSources: [
                AgentLogSource(
                    defaultPath: ".local/share/kilo",
                    overrideVariable: "XDG_DATA_HOME",
                    overrideSubpath: "kilo",
                    extensions: ["db-wal"],
                    maxDepth: 2
                ),
                AgentLogSource(defaultPath: ".kilocode/cli", extensions: ["db-wal"], maxDepth: 2),
            ]
        ),
        AgentDefinition(
            id: "mimo-code",
            engine: "MiMo Code",
            processNames: ["mimo"],
            logSources: [
                AgentLogSource(
                    defaultPath: ".local/share/mimocode",
                    overrideVariable: "MIMOCODE_HOME",
                    overrideSubpath: "data",
                    extensions: ["db-wal"],
                    maxDepth: 2
                )
            ]
        ),
        AgentDefinition(
            id: "kiro",
            engine: "Kiro",
            processNames: ["kiro-cli"],
            logSources: [
                // 只在一輪 turn 結束才寫，是弱訊號；工作中主要靠第二層。
                AgentLogSource(defaultPath: ".kiro/sessions", extensions: ["jsonl", "json"], maxDepth: 3)
            ]
        ),
        AgentDefinition(
            id: "grok",
            engine: "Grok",
            processNames: ["grok"],
            processPrefixes: ["grok-"],
            logSources: [
                AgentLogSource(defaultPath: ".grok/sessions", extensions: ["json", "jsonl"], maxDepth: 2)
            ]
        ),
        AgentDefinition(
            id: "mistral-vibe",
            engine: "Mistral Vibe",
            processNames: ["vibe", "mistral-vibe"],
            logSources: [
                AgentLogSource(
                    defaultPath: ".vibe/logs/session",
                    overrideVariable: "VIBE_HOME",
                    overrideSubpath: "logs/session",
                    extensions: ["jsonl", "json"],
                    maxDepth: 2
                ),
                AgentLogSource(
                    defaultPath: ".vibe/logs/sessions",
                    overrideVariable: "VIBE_HOME",
                    overrideSubpath: "logs/sessions",
                    extensions: ["jsonl", "json"],
                    maxDepth: 2
                ),
            ]
        ),
        AgentDefinition(
            id: "hermes",
            engine: "Hermes",
            processNames: ["hermes"],
            logSources: [
                // `state.db-wal` 隨工作變動（本機驗證）；HERMES_HOME 本身就是 `.hermes`。
                AgentLogSource(
                    defaultPath: ".hermes",
                    overrideVariable: "HERMES_HOME",
                    extensions: ["db-wal"],
                    maxDepth: 1
                ),
                AgentLogSource(
                    defaultPath: ".hermes/logs",
                    overrideVariable: "HERMES_HOME",
                    overrideSubpath: "logs",
                    extensions: ["db-wal", "log"],
                    maxDepth: 1
                ),
            ]
        ),
        AgentDefinition(
            id: "openclaw",
            engine: "OpenClaw",
            processNames: ["openclaw"],
            logSources: [
                // `<agent>/sessions/*.jsonl`
                AgentLogSource(defaultPath: ".openclaw/agents", extensions: ["jsonl"], maxDepth: 3)
            ]
        ),
        AgentDefinition(
            id: "cline",
            engine: "Cline",
            processNames: ["cline"],
            logSources: [
                AgentLogSource(
                    defaultPath: ".cline/data/sessions",
                    overrideVariable: "CLINE_DATA_DIR",
                    overrideSubpath: "sessions",
                    extensions: ["json"],
                    maxDepth: 2
                )
            ]
        ),
        AgentDefinition(
            id: "continue",
            engine: "Continue",
            processNames: ["cn"],
            logSources: [
                AgentLogSource(defaultPath: ".continue/sessions", extensions: ["json"], maxDepth: 1)
            ]
        ),
        AgentDefinition(
            id: "codebuff",
            engine: "Codebuff",
            processNames: ["codebuff"],
            logSources: [
                // `<project>/chats/*.json`
                AgentLogSource(defaultPath: ".config/manicode/projects", extensions: ["json"], maxDepth: 3)
            ]
        ),
        AgentDefinition(
            id: "rovo",
            engine: "Rovo Dev",
            processNames: ["rovo", "acli"],
            logSources: [
                AgentLogSource(defaultPath: ".rovodev/sessions", extensions: ["json"], maxDepth: 2)
            ]
        ),
        AgentDefinition(
            id: "autohand",
            engine: "Autohand",
            processNames: ["autohand"],
            logSources: [
                AgentLogSource(defaultPath: ".autohand/sessions", extensions: ["json"], maxDepth: 1)
            ]
        ),
        AgentDefinition(
            id: "aug",
            engine: "Auggie",
            processNames: ["auggie"],
            logSources: [
                // 副檔名不明，空集合＝全收（這個根只有 session 檔）。
                AgentLogSource(defaultPath: ".augment/sessions", extensions: [], maxDepth: 2)
            ]
        ),
        AgentDefinition(
            id: "command-code",
            engine: "Command Code",
            processNames: ["command-code"],
            logSources: [
                AgentLogSource(defaultPath: ".commandcode/projects", extensions: ["jsonl"], maxDepth: 3)
            ]
        ),
        // 以下沒有全域 log（跡證在專案目錄裡，Chorus 不會去掃使用者的專案），
        // 只靠第二層的行程活動偵測。
        AgentDefinition(id: "aider", engine: "Aider", processNames: ["aider"], pythonModules: ["aider"]),
        AgentDefinition(id: "crush", engine: "Charm Crush", processNames: ["crush"]),
        AgentDefinition(id: "trae", engine: "Trae CN", processNames: ["traecli"]),
        AgentDefinition(id: "devin", engine: "Devin", processNames: ["devin"]),
        AgentDefinition(id: "ante", engine: "Ante", processNames: ["ante"]),
    ]
}
