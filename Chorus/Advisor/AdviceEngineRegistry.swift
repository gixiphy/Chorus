import ChorusCore
import Foundation
import Observation

/// 已知 CLI 目錄的一筆（DESIGN-ai-provider-layer §0.1）。
/// 偵測到誰就在設定頁列誰；預設引擎＝claude（存在時）。
///
/// 每一筆的參數組都是**實測**出來的，不是照文件抄的——各家 headless 行為
/// 差異很大（誰需要權限旗標、圖片怎麼送、回應在 stdout 還是 envelope 的哪個
/// 欄位），猜錯的症狀往往是「跑完了但沒有輸出」這種難查的失敗。
struct KnownCLIEngine: Identifiable, Sendable {
    /// 引擎能力（E0 正式化）。消費端聲明需求、選擇時過濾——
    /// 光環境顧問要 `.vision`（送照片），調音顧問純文字、什麼都不要求。
    /// 目前六家都支援看圖，旗標在此刻不改變任何行為；它存在的意義是
    /// 讓「接一個純文字引擎」成為加一筆目錄的事，而不是改選擇邏輯的事。
    enum Capability: Sendable, Hashable {
        /// 能吃影像輸入（路徑讓它讀，或參數直接附加）。
        case vision
    }

    let id: String
    let executableName: String
    let displayName: String
    let capabilities: Set<Capability>
    let codec: AdviceOutputCodec
    /// 照片怎麼送到模型手上；決定 prompt 要不要講路徑。
    let photoDelivery: AdvicePrompt.PhotoDelivery
    /// 接入尚未打通前標「待接入」不可選。
    let pendingIntegration: Bool
    /// headless／讀圖行為尚未在本機驗證過：可選，標「實驗性」。
    let experimental: Bool
    /// 支援 `--model`／`-m`：設定頁給一個自訂模型欄位。
    let supportsModelSelection: Bool
    /// 模型欄位的格式提示。各家寫法不同——尤其 opencode 要 `provider/model`，
    /// 只填模型名會直接失敗，這種事不該讓使用者自己試出來。
    let modelHint: String
    /// 可靠的模型列舉方式；沒有就 nil（欄位維持純輸入，不編造清單）。
    let modelListing: ModelListing?
    /// 靜態建議項。只放**設計上穩定**的東西（claude 的別名恆指向最新模型），
    /// 不放具體版本號——那種清單放著就會過期。
    let suggestedModels: [String]

    /// 模型清單的來源。各家不同，照實反映。
    enum ModelListing: Sendable {
        /// 跑 `<cli> <arguments>` 取得清單。
        case command(arguments: [String], format: CommandFormat)
        /// codex 沒有非互動的列舉指令（`codex models` 會轉進互動式 TUI
        /// 並因非 TTY 失敗），但它自己在 `~/.codex/models_cache.json`
        /// 維護一份抓好的清單——直接讀那份，唯讀、不動使用者的檔案。
        case codexModelsCache

        enum CommandFormat: Sendable {
            /// 每行一個 slug（opencode：`provider/model`）。
            case plainLines
            /// 散文清單，項目以 `*`／`-` 起頭（grok：`  * grok-4.6 (default)`）。
            case markerList
            /// `<slug>\t<顯示名>`（agy）。
            case tabSeparated
            /// 空白對齊欄位＋表頭（pi：`provider model … images`）。
            /// 跳過首欄為 `provider` 的表頭列，取前兩欄拼成 `provider/model`，
            /// 且只收 `images == yes` 的列——選到純文字模型會讓看圖分析直接失敗。
            case whitespaceColumns
        }
    }
    /// 給 prompt 的照片讀取措辭（僅 `.pathInPrompt` 用得到）。
    let readInstruction: String
    /// 未登入時提示使用者到終端執行的指令。
    let loginCommand: String

    /// 單發呼叫需要的執行期資訊。
    struct RunContext {
        /// 這次分析的照片沙箱目錄——只放本次要看的縮圖與 schema 檔。
        /// 需要明示宣告工作目錄的 CLI（agy `--add-dir`、codex `--cd`、
        /// grok `--cwd`、opencode `--dir`）都指向這裡。
        var sandbox: URL?
        /// 寫在沙箱裡的 JSON Schema 檔（吃 schema 檔的引擎才用）。
        var schemaFile: URL?
        /// 使用者填的模型字串；留空＝用 CLI 自己的預設。
        var model: String?
        /// 縮圖路徑，依序對應 prompt 裡的標註。
        var photoPaths: [String] = []
        /// 子行程逾時；CLI 自帶 timeout 參數的會設得比它略短，
        /// 讓 CLI 自己乾淨收尾而不是被我們 SIGTERM。
        var timeout: Duration = .seconds(120)
    }

    /// 單發呼叫的參數與 prompt 傳遞方式。
    /// claude 走 stdin（prompt 長，避開 argv）；其餘以參數帶 prompt。
    func invocation(prompt: String, run: RunContext) -> (arguments: [String], stdin: String?) {
        switch id {
        case "claude":
            var arguments = ["-p", "--output-format", "json", "--allowedTools", "Read"]
            if let model = run.model, !model.isEmpty { arguments += ["--model", model] }
            return (arguments, prompt)

        case "agy":
            var arguments = ["-p", prompt, "--output-format", "json"]
            // headless 無法互動式詢問權限，read_file 會被自動拒絕（實測 1.1.19／1.1.22：
            // 退出碼 0、status 仍是 SUCCESS、response 空字串，原因只在 stderr）。
            // --add-dir 明示宣告工作目錄即可放行，範圍限於本次分析的沙箱；
            // 不用 --dangerously-skip-permissions（那會放行所有工具）。
            if let sandbox = run.sandbox { arguments += ["--add-dir", sandbox.path] }
            if let schema = run.schemaFile { arguments += ["--json-schema", schema.path] }
            if let model = run.model, !model.isEmpty { arguments += ["--model", model] }
            arguments += ["--print-timeout", "\(Self.innerTimeoutSeconds(run))s"]
            return (arguments, nil)

        case "grok":
            // 讀檔不需要額外權限旗標（實測 1.0.5 直接可用）。
            var arguments = ["-p", prompt, "--output-format", "json"]
            if let sandbox = run.sandbox { arguments += ["--cwd", sandbox.path] }
            if let model = run.model, !model.isEmpty { arguments += ["--model", model] }
            return (arguments, nil)

        case "codex":
            // --image 直接附加影像：不經讀檔工具，也就沒有權限問題。
            // --skip-git-repo-check 必要——沙箱目錄不是 git repo。
            var arguments = ["exec"]
            for path in run.photoPaths { arguments += ["--image", path] }
            arguments += ["--sandbox", "read-only", "--skip-git-repo-check"]
            if let sandbox = run.sandbox { arguments += ["--cd", sandbox.path] }
            if let model = run.model, !model.isEmpty { arguments += ["--model", model] }
            arguments.append(prompt)
            return (arguments, nil)

        case "opencode":
            // -f 是陣列選項：**訊息必須排在它前面**，否則訊息會被當成檔案路徑
            // 吃掉（實測會直接回 "File not found: <整段訊息>"）。
            var arguments = ["run", "--dir", run.sandbox?.path ?? FileManager.default.temporaryDirectory.path]
            if let model = run.model, !model.isEmpty { arguments += ["--model", model] }
            arguments.append(prompt)
            for path in run.photoPaths { arguments += ["-f", path] }
            return (arguments, nil)

        case "pi":
            // 照片以 @path 附加，不動讀檔工具 → --no-tools 直接免掉權限與誤觸。
            // pi 沒有 --cd／--cwd，會從行程 cwd 自動撈 AGENTS.md／CLAUDE.md、
            // extensions、skills、prompt templates——沙箱指不過去，只能把探索全關掉，
            // 否則使用者機器上的擴充會默默改變顧問行為（難查、且無法重現）。
            // 參數順序：pi [options] [@files...] [messages...]，@檔案排在訊息前
            //（與 opencode 的 -f 相反方向）。
            var arguments = ["-p", "--no-session", "--no-tools",
                             "--no-context-files", "--no-extensions",
                             "--no-skills", "--no-prompt-templates"]
            if let model = run.model, !model.isEmpty { arguments += ["--model", model] }
            for path in run.photoPaths { arguments.append("@" + path) }
            arguments.append(prompt)
            return (arguments, nil)

        default:
            return (["-p", prompt], nil)
        }
    }

    /// CLI 自己的逾時：比我們的 watchdog 早 10 秒收手，讓它吐錯誤而不是被砍。
    private static func innerTimeoutSeconds(_ run: RunContext) -> Int {
        max(Int(run.timeout.components.seconds) - 10, 30)
    }

    /// Gemini CLI 不在目錄中：Google 已於 2026-06-18 停用（個人帳號停止服務），
    /// 官方遷移目標即 Antigravity CLI（agy）。
    static let catalog: [KnownCLIEngine] = [
        KnownCLIEngine(
            id: "claude", executableName: "claude", displayName: "Claude Code",
            capabilities: [.vision],
            codec: .jsonEnvelope, photoDelivery: .pathInPrompt,
            pendingIntegration: false, experimental: false, supportsModelSelection: true,
            modelHint: String(localized: "別名 opus／sonnet／fable，或完整名稱如 claude-opus-5"),
            modelListing: nil,
            suggestedModels: ["opus", "sonnet", "fable"],
            readInstruction: "read it with the Read tool before analyzing",
            loginCommand: "claude /login"
        ),
        KnownCLIEngine(
            id: "agy", executableName: "agy", displayName: "Antigravity",
            capabilities: [.vision],
            codec: .responseEnvelope, photoDelivery: .pathInPrompt,
            pendingIntegration: false, experimental: false, supportsModelSelection: true,
            modelHint: String(localized: "slug，如 gemini-3.1-pro-high、claude-sonnet-4-6"),
            modelListing: .command(arguments: ["models"], format: .tabSeparated),
            suggestedModels: [],
            readInstruction: "read the photo before analyzing",
            loginCommand: "agy"
        ),
        KnownCLIEngine(
            id: "grok", executableName: "grok", displayName: "Grok Build",
            capabilities: [.vision],
            codec: .textEnvelope, photoDelivery: .pathInPrompt,
            pendingIntegration: false, experimental: false, supportsModelSelection: true,
            modelHint: String(localized: "模型 ID"),
            modelListing: .command(arguments: ["models"], format: .markerList),
            suggestedModels: [],
            readInstruction: "read the photo before analyzing",
            loginCommand: "grok"
        ),
        KnownCLIEngine(
            id: "codex", executableName: "codex", displayName: "Codex CLI",
            capabilities: [.vision],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: false, supportsModelSelection: true,
            modelHint: String(localized: "模型名稱，如 gpt-5.6-terra"),
            modelListing: .codexModelsCache,
            suggestedModels: [],
            readInstruction: "the photo is attached",
            loginCommand: "codex login"
        ),
        KnownCLIEngine(
            id: "opencode", executableName: "opencode", displayName: "OpenCode",
            capabilities: [.vision],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: false, supportsModelSelection: true,
            modelHint: String(localized: "provider/model 格式"),
            modelListing: .command(arguments: ["models"], format: .plainLines),
            suggestedModels: [],
            readInstruction: "the photo is attached",
            loginCommand: "opencode auth login"
        ),
        KnownCLIEngine(
            id: "pi", executableName: "pi", displayName: "Pi",
            capabilities: [.vision],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: false, supportsModelSelection: true,
            modelHint: String(localized: "provider/model 格式，如 opencode-go/kimi-k2.7-code"),
            modelListing: .command(arguments: ["--list-models"], format: .whitespaceColumns),
            suggestedModels: [],
            readInstruction: "the photo is attached",
            loginCommand: "pi"
        ),
    ]
}

/// 引擎偵測與選擇（Registry 最小版；能力旗標等正式化屬接入層 E0）。
/// 掃描順序：SettingsStore 自訂路徑 → PATH → 已知安裝位置。
@MainActor
@Observable
final class AdviceEngineRegistry {
    struct DetectedEngine: Identifiable {
        let engine: KnownCLIEngine
        let url: URL
        var version: String?
        var id: String { engine.id }
        /// 接入未打通的引擎偵測到也不可選。
        var selectable: Bool { !engine.pendingIntegration }
    }

    private(set) var detected: [DetectedEngine] = []
    /// 各引擎可選的模型（engine id → slug）。列不到的維持空陣列，
    /// UI 就只顯示輸入欄位。
    private(set) var models: [String: [String]] = [:]

    @ObservationIgnored private let settings: SettingsStore

    /// GUI app 的 PATH 通常只有系統目錄，補上常見安裝位置。
    /// 家目錄安裝（官方 installer 位置）排在 Homebrew 之前：同一台機器可能有多份
    /// 安裝，優先挑終端實際在用的那顆，鑰匙圈授權（永遠允許）才共用得到，
    /// 否則每次分析都會再跳一次鑰匙圈授權視窗。
    private static let knownDirectories = [
        NSHomeDirectory() + "/.local/bin",
        NSHomeDirectory() + "/.claude/local",
        NSHomeDirectory() + "/.grok/bin",
        NSHomeDirectory() + "/.codex/bin",
        NSHomeDirectory() + "/bin",
        "/opt/homebrew/bin", "/usr/local/bin",
    ]

    /// `scanOnInit: false` 供測試：不掃描實機、不 spawn `--version`，
    /// 之後以 `injectDetected` 布置狀態。
    init(settings: SettingsStore, scanOnInit: Bool = true) {
        self.settings = settings
        if scanOnInit { rescan() }
    }

    /// 目前選定且可用的引擎（不要求任何能力）；純文字消費端（調音顧問）用這個。
    var activeEngine: DetectedEngine? { activeEngine(requiring: []) }

    /// 選定且具備所需能力的引擎；選定的不合格（被停用、缺能力、已移除）時
    /// 回落 claude → 任一合格引擎。回落是為了「按了分析不該沒反應」，
    /// 但**永不**回落到被使用者停用的引擎——停用＝不准 spawn，計費在使用者
    /// 的訂閱上，這條線比可用性硬。
    func activeEngine(requiring required: Set<KnownCLIEngine.Capability>) -> DetectedEngine? {
        let usable = detected.filter {
            $0.selectable && isEnabled($0.id) && $0.engine.capabilities.isSuperset(of: required)
        }
        if let chosen = usable.first(where: { $0.id == settings.advisorEngineID }) {
            return chosen
        }
        return usable.first { $0.id == "claude" } ?? usable.first
    }

    // MARK: - 啟用開關（E0）

    /// 開關只控制「是否允許 spawn」（DESIGN §2.1）；偵測與列出照舊。
    func isEnabled(_ engineID: String) -> Bool {
        !settings.advisorDisabledEngines.contains(engineID)
    }

    func setEnabled(_ enabled: Bool, engineID: String) {
        if enabled {
            settings.advisorDisabledEngines.remove(engineID)
        } else {
            settings.advisorDisabledEngines.insert(engineID)
        }
    }

    /// 測試注入（同 TestHooks 慣例）：直接布置偵測結果，跳過實機掃描。
    func injectDetected(_ entries: [DetectedEngine]) {
        detected = entries
    }

    func rescan() {
        detected = KnownCLIEngine.catalog.compactMap { engine in
            locate(engine).map { DetectedEngine(engine: engine, url: $0, version: nil) }
        }
        // 靜態建議先就位；能列舉的等版本確定後再補上（見 refreshModels）
        for entry in detected {
            models[entry.id] = entry.engine.suggestedModels
        }
        fetchVersions()
    }

    /// 使用者按「重新掃描」時連模型清單一起重抓（忽略版本快取）。
    func rescanIncludingModels() {
        settings.advisorModelCache = [:]
        rescan()
    }

    /// `<cli> models` 的輸出解析。純函式，單獨測。
    nonisolated static func parseModels(
        _ output: String,
        format: KnownCLIEngine.ModelListing.CommandFormat
    ) -> [String] {
        let lines = output.components(separatedBy: .newlines)
        switch format {
        case .tabSeparated:
            // agy：`<slug>\t<顯示名>`。沒有 tab 的行（"Fetching available
            // models..." 之類）一律略過。
            return lines.compactMap { line in
                let parts = line.split(separator: "\t", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let slug = parts[0].trimmingCharacters(in: .whitespaces)
                return slug.isEmpty ? nil : slug
            }
        case .plainLines:
            // opencode：每行就是一個 provider/model。沒有斜線的是雜訊行。
            return lines
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.contains("/") && !$0.contains(" ") }
        case .markerList:
            // grok：`  * grok-4.6 (default)` / `  - grok-4.5`；
            // 標題行（"Available models:"）沒有項目符號，自然被濾掉。
            return lines.compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") else { return nil }
                let body = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                // 去掉 "(default)" 之類的尾註
                let slug = body.split(separator: " ").first.map(String.init) ?? body
                return slug.isEmpty ? nil : slug
            }
        case .whitespaceColumns:
            // pi：空白對齊欄位＋表頭。跳過首欄字面值 `provider` 的表頭列，
            // 取前兩欄拼成 `provider/model`，只收 images == yes。
            return lines.compactMap { line -> String? in
                let parts = line.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard parts.count >= 6, parts[0] != "provider" else { return nil }
                guard parts.last?.lowercased() == "yes" else { return nil }
                let provider = parts[0]
                let model = parts[1]
                guard !provider.isEmpty, !model.isEmpty else { return nil }
                return "\(provider)/\(model)"
            }
        }
    }

    /// 版本確定後補上模型清單。**以 CLI 版本為快取鍵**：版本沒變就用快取，
    /// 升版即重抓——列舉會打網路，不該每次開設定頁都跑一遍。
    private func refreshModels(for entry: DetectedEngine) {
        guard let listing = entry.engine.modelListing, let version = entry.version else { return }
        let cacheKey = "\(entry.id)|\(version)"
        if let cached = settings.advisorModelCache[cacheKey], !cached.isEmpty {
            models[entry.id] = cached
            return
        }
        let url = entry.url
        let engineID = entry.id
        Task.detached { [weak self] in
            let parsed: [String]
            switch listing {
            case let .command(arguments, format):
                guard let output = Self.runListing(at: url, arguments: arguments) else { return }
                parsed = Self.parseModels(output, format: format)
            case .codexModelsCache:
                guard let data = FileManager.default.contents(atPath: Self.codexModelsCachePath) else { return }
                parsed = Self.parseCodexModelsCache(data)
            }
            guard !parsed.isEmpty else { return }
            await MainActor.run {
                guard let self else { return }
                self.models[engineID] = parsed
                self.settings.advisorModelCache[cacheKey] = parsed
            }
        }
    }

    nonisolated static var codexModelsCachePath: String {
        NSString(string: "~/.codex/models_cache.json").expandingTildeInPath
    }

    /// codex 的模型快取：取 `visibility == "list"` 的 slug——
    /// 標 `hide` 的是它自己不放進選單的（legacy／內部），我們也不該列。
    nonisolated static func parseCodexModelsCache(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = object["models"] as? [[String: Any]]
        else { return [] }
        return models.compactMap { model in
            guard let slug = model["slug"] as? String, !slug.isEmpty else { return nil }
            // 沒有 visibility 欄位時保守納入（欄位是新加的就不該整份變空）
            guard (model["visibility"] as? String ?? "list") == "list" else { return nil }
            return slug
        }
    }

    /// 列舉會打網路（實測 grok／opencode 各需十餘秒），逾時放寬到 30 秒；
    /// 失敗只是沒有下拉選單，輸入欄位照常可用。
    private nonisolated static func runListing(at url: URL, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        process.environment = CLIProcessRunner.whitelistedEnvironment(
            executableDirectory: url.deletingLastPathComponent().path
        )
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning { process.terminate(); return nil }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }

    private func locate(_ engine: KnownCLIEngine) -> URL? {
        var candidates: [String] = []
        if let custom = settings.advisorCustomPaths[engine.id], !custom.isEmpty {
            candidates.append((custom as NSString).expandingTildeInPath)
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for dir in pathDirs + Self.knownDirectories {
            candidates.append(dir + "/" + engine.executableName)
        }
        let fm = FileManager.default
        return candidates
            .first { fm.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// 各引擎 `--version` 供診斷；失敗不影響可用性。
    private func fetchVersions() {
        for entry in detected {
            let url = entry.url
            Task.detached { [weak self] in
                let version = Self.readVersion(of: url)
                await MainActor.run {
                    guard let self, let index = self.detected.firstIndex(where: { $0.id == entry.id }),
                          self.detected[index].url == url else { return }
                    self.detected[index].version = version
                    self.refreshModels(for: self.detected[index])
                }
            }
        }
    }

    private nonisolated static func readVersion(of url: URL) -> String? {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--version"]
        process.environment = CLIProcessRunner.whitelistedEnvironment(executableDirectory: url.deletingLastPathComponent().path)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first
    }
}
