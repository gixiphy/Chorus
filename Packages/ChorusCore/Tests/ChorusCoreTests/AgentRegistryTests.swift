import Foundation
import Testing
@testable import ChorusCore

@Suite("AgentRegistry")
struct AgentRegistryTests {
    private let home = URL(filePath: "/Users/tester", directoryHint: .isDirectory)

    private func source(_ id: String, _ index: Int = 0) throws -> AgentLogSource {
        let definition = try #require(AgentRegistry.definition(id: id))
        return try #require(definition.logSources.dropFirst(index).first)
    }

    // MARK: - 表格本身

    @Test("Every definition carries a display name and lowercase process names")
    func definitionsAreWellFormed() {
        #expect(!AgentRegistry.all.isEmpty)
        for definition in AgentRegistry.all {
            #expect(!definition.id.isEmpty)
            #expect(!definition.engine.isEmpty, "\(definition.id) 沒有顯示名")
            #expect(!definition.processNames.isEmpty, "\(definition.id) 沒有行程名")
            for name in definition.processNames {
                #expect(name == name.lowercased(), "\(definition.id)：行程名 \(name) 不是小寫")
                #expect(!name.contains("/"), "\(definition.id)：行程名 \(name) 應該是 basename")
                #expect(
                    !AgentRegistry.interpreterNames.contains(name),
                    "\(definition.id)：\(name) 是直譯器名，會把所有 node／python 都當 agent"
                )
            }
            for prefix in definition.processPrefixes {
                #expect(prefix == prefix.lowercased(), "\(definition.id)：前綴 \(prefix) 不是小寫")
            }
            for module in definition.pythonModules {
                #expect(module == module.lowercased(), "\(definition.id)：模組 \(module) 不是小寫")
            }
        }
    }

    @Test("No two definitions claim the same id, process name or display name")
    func noCollisions() {
        var ids = Set<String>()
        var names = Set<String>()
        var engines = Set<String>()
        for definition in AgentRegistry.all {
            #expect(ids.insert(definition.id).inserted, "重複 id：\(definition.id)")
            // engine 是合併兩層樣本時的去重鍵（見 AgentActivityMerger），撞名會把兩家算成一家。
            #expect(engines.insert(definition.engine).inserted, "重複顯示名：\(definition.engine)")
            for name in definition.processNames {
                #expect(names.insert(name).inserted, "重複行程名：\(name)")
            }
        }
    }

    @Test("definition(id:) finds every registered agent and nothing else")
    func lookup() {
        for definition in AgentRegistry.all {
            #expect(AgentRegistry.definition(id: definition.id) == definition)
        }
        #expect(AgentRegistry.definition(id: "no-such-agent") == nil)
    }

    @Test("Agents without a global log directory rely on process detection only")
    func processOnlyAgents() throws {
        for id in ["aider", "crush", "trae", "devin", "ante"] {
            let definition = try #require(AgentRegistry.definition(id: id))
            #expect(definition.logSources.isEmpty, "\(id) 不該有 log 根")
        }
        #expect(try #require(AgentRegistry.definition(id: "aider")).pythonModules == ["aider"])
    }

    // MARK: - 掃描成本的護欄

    @Test("Every root stays inside the scan budget")
    func scanBudget() {
        for definition in AgentRegistry.all {
            for source in definition.logSources {
                #expect(source.maxDepth >= 1, "\(definition.id)：深度至少 1")
                #expect(source.maxDepth <= 6, "\(definition.id)：深度 \(source.maxDepth) 超過預算")
                #expect(source.maxEntries <= 5_000, "\(definition.id)：項目上限 \(source.maxEntries) 超過預算")
                #expect(!source.defaultPath.hasPrefix("~"), "\(definition.id)：路徑不該含 ~")
                #expect(!source.defaultPath.hasPrefix("/"), "\(definition.id)：路徑要相對 $HOME")
            }
        }
    }

    @Test("Every root skips the shared list of noisy directories")
    func skippedDirectories() throws {
        #expect(AgentRegistry.defaultSkippedDirectories.contains("node_modules"))
        for definition in AgentRegistry.all {
            for source in definition.logSources {
                #expect(source.effectiveSkippedDirectories.isSuperset(of: AgentRegistry.defaultSkippedDirectories))
            }
        }
        // 這兩個根的陷阱是本機實測出來的：`memory/` 有 21 個子目錄、`canvases/`／`mcps/` 一堆 .d.ts。
        #expect(try source("claude").skippedDirectories.contains("memory"))
        #expect(try source("cursor").skippedDirectories.isSuperset(of: ["canvases", "mcps"]))
    }

    @Test("SQLite-backed agents accept db-wal only")
    func sqliteExtensions() throws {
        let antigravity = try source("antigravity")
        #expect(antigravity.accepts(pathExtension: "db-wal"))
        // `.db-shm` 的 mtime 會被任何第三方的唯讀輪詢碰到；`.db` 要 checkpoint 才動。
        #expect(!antigravity.accepts(pathExtension: "db-shm"))
        #expect(!antigravity.accepts(pathExtension: "db"))
        #expect(antigravity.maxDepth == 1)
        for id in ["opencode", "goose", "kilo", "mimo-code", "hermes"] {
            let definition = try #require(AgentRegistry.definition(id: id))
            #expect(definition.logSources.contains { $0.extensions.contains("db-wal") })
            for source in definition.logSources {
                #expect(!source.extensions.contains("db-shm"), "\(id) 不該收 db-shm")
            }
        }
    }

    @Test("An empty extension set accepts everything")
    func openExtensionSet() throws {
        let auggie = try source("aug")
        #expect(auggie.extensions.isEmpty)
        #expect(auggie.accepts(pathExtension: "json"))
        #expect(auggie.accepts(pathExtension: "whatever"))
    }

    @Test("Extension matching is case insensitive")
    func extensionCase() throws {
        let claude = try source("claude")
        #expect(claude.accepts(pathExtension: "JSONL"))
        #expect(!claude.accepts(pathExtension: "json"))
    }

    // MARK: - resolveRoot

    @Test("Without overrides every root hangs off $HOME")
    func defaultRoots() throws {
        #expect(try source("claude").resolveRoot(home: home, environment: [:]).path
            == "/Users/tester/.claude/projects")
        #expect(try source("codex").resolveRoot(home: home, environment: [:]).path
            == "/Users/tester/.codex/sessions")
        #expect(try source("goose", 1).resolveRoot(home: home, environment: [:]).path
            == "/Users/tester/Library/Application Support/goose/sessions")
    }

    @Test("Override variables replace the home-relative root")
    func overrides() throws {
        #expect(try source("claude").resolveRoot(home: home, environment: ["CLAUDE_CONFIG_DIR": "/x"]).path
            == "/x/projects")
        #expect(try source("codex").resolveRoot(home: home, environment: ["CODEX_HOME": "/tmp/codex-home"]).path
            == "/tmp/codex-home/sessions")
        #expect(try source("opencode").resolveRoot(home: home, environment: ["XDG_DATA_HOME": "/data"]).path
            == "/data/opencode")
        #expect(try source("goose").resolveRoot(home: home, environment: ["XDG_DATA_HOME": "/data"]).path
            == "/data/goose/sessions")
        // 變數本身就是根的兩家。
        #expect(try source("kimi").resolveRoot(home: home, environment: ["KIMI_SHARE_DIR": "/share/kimi"]).path
            == "/share/kimi")
        #expect(try source("hermes").resolveRoot(home: home, environment: ["HERMES_HOME": "/opt/hermes"]).path
            == "/opt/hermes")
    }

    @Test("An unrelated or empty variable leaves the default root alone")
    func emptyOverride() throws {
        let claude = try source("claude")
        // `export CLAUDE_CONFIG_DIR=` 照著走會掃到 /projects，比用預設糟。
        #expect(claude.resolveRoot(home: home, environment: ["CLAUDE_CONFIG_DIR": ""]).path
            == "/Users/tester/.claude/projects")
        #expect(claude.resolveRoot(home: home, environment: ["CODEX_HOME": "/x"]).path
            == "/Users/tester/.claude/projects")
        // 第二個 goose 根沒有覆寫變數，XDG 設了也不動。
        #expect(try source("goose", 1).resolveRoot(home: home, environment: ["XDG_DATA_HOME": "/data"]).path
            == "/Users/tester/Library/Application Support/goose/sessions")
    }

    @Test("resolvedLogSources expands every registered root once")
    func resolvedSources() {
        let resolved = AgentRegistry.resolvedLogSources(home: home, environment: [:])
        #expect(resolved.count == AgentRegistry.all.reduce(0) { $0 + $1.logSources.count })
        #expect(resolved.allSatisfy { $0.root.path.hasPrefix("/Users/tester/") })
        #expect(resolved.contains { $0.engine == "Claude Code" && $0.root.lastPathComponent == "projects" })
        #expect(!resolved.contains { $0.engine == "Aider" })

        let overridden = AgentRegistry.resolvedLogSources(
            home: home,
            environment: ["CLAUDE_CONFIG_DIR": "/alt/claude"]
        )
        #expect(overridden.contains { $0.engine == "Claude Code" && $0.root.path == "/alt/claude/projects" })
    }

    @Test("The convenience initialiser produces a jsonl root with the default skips")
    func testHelperInitialiser() {
        let resolved = ResolvedAgentLogSource(engine: "Test", root: URL(filePath: "/tmp/agent-logs"))
        #expect(resolved.engine == "Test")
        #expect(resolved.source.extensions == ["jsonl"])
        #expect(resolved.source.maxDepth == 6)
        #expect(resolved.source.effectiveSkippedDirectories == AgentRegistry.defaultSkippedDirectories)
    }
}
