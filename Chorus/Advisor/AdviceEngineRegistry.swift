import ChorusCore
import Foundation
import Observation

/// 已知 CLI 目錄的一筆（DESIGN-ai-provider-layer §0.1）。
/// 偵測到誰就在設定頁列誰；預設引擎＝claude（存在時）。
///
/// 每一筆的參數組都是**實測**出來的，不是照文件抄的——各家 headless 行為
/// 差異很大（誰需要權限旗標、圖片怎麼送、回應在 stdout 還是 envelope 的哪個
/// 欄位），猜錯的症狀往往是「跑完了但沒有輸出」這種難查的失敗。
///
/// 模型一律用各 CLI 自己的預設：模型名／別名的壽命比 App 的發版週期短得多，
/// 讓使用者在設定頁填一個會過期的字串，只會製造「昨天還好的引擎今天壞了」。
struct KnownCLIEngine: Identifiable, Sendable {
    /// 引擎能力（E0 正式化）。消費端聲明需求、選擇時過濾——
    /// 光環境顧問要 `.vision`（送照片），調音顧問純文字、什麼都不要求。
    enum Capability: Sendable, Hashable {
        /// 能吃影像輸入（路徑讓它讀，或參數直接附加）。
        case vision
    }

    /// 登入狀態的探測方式。三種都只**讀**狀態，不碰憑證內容、不寫任何檔。
    enum AuthProbe: Sendable {
        /// 跑 `<cli> <arguments>`：退出碼 0 = 已登入。
        case command(arguments: [String])
        /// 憑證檔（相對家目錄）存在即已登入。
        case credentialFile(path: String)
        /// 環境變數任一存在且非空即已登入（吃 API key 的 CLI）。
        case environmentKey(names: [String])
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
    /// headless 行為尚未在本機驗證過：可選，標「實驗性」。
    let experimental: Bool
    /// 這家 CLI 額外需要的環境變數，在 `CLIProcessRunner.whitelistedEnvironment`
    /// 之後合併（goose 不設 `GOOSE_MODE` 會在非互動模式下等權限確認）。
    var extraEnvironment: [String: String] = [:]
    /// 登入狀態怎麼查；沒有可靠查法就 nil（狀態顯示為未知，照常列出）。
    var authProbe: AuthProbe?
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
        /// 縮圖路徑，依序對應 prompt 裡的標註。
        var photoPaths: [String] = []
        /// 子行程逾時；CLI 自帶 timeout 參數的會設得比它略短，
        /// 讓 CLI 自己乾淨收尾而不是被我們 SIGTERM。
        var timeout: Duration = .seconds(120)
    }

    /// 單發呼叫的參數與 prompt 傳遞方式。
    /// claude 與 amp 走 stdin（prompt 長，避開 argv）；其餘以參數帶 prompt。
    func invocation(prompt: String, run: RunContext) -> (arguments: [String], stdin: String?) {
        switch id {
        case "claude", "openclaude":
            return (["-p", "--output-format", "json", "--allowedTools", "Read"], prompt)

        case "agy":
            var arguments = ["-p", prompt, "--output-format", "json"]
            // headless 無法互動式詢問權限，read_file 會被自動拒絕（實測 1.1.19／1.1.22：
            // 退出碼 0、status 仍是 SUCCESS、response 空字串，原因只在 stderr）。
            // --add-dir 明示宣告工作目錄即可放行，範圍限於本次分析的沙箱；
            // 不用 --dangerously-skip-permissions（那會放行所有工具）。
            if let sandbox = run.sandbox { arguments += ["--add-dir", sandbox.path] }
            if let schema = run.schemaFile { arguments += ["--json-schema", schema.path] }
            arguments += ["--print-timeout", "\(Self.innerTimeoutSeconds(run))s"]
            return (arguments, nil)

        case "grok":
            // 讀檔不需要額外權限旗標（實測 1.0.5 直接可用）。
            var arguments = ["-p", prompt, "--output-format", "json"]
            if let sandbox = run.sandbox { arguments += ["--cwd", sandbox.path] }
            return (arguments, nil)

        case "codex":
            // --image 直接附加影像：不經讀檔工具，也就沒有權限問題。
            // --skip-git-repo-check 必要——沙箱目錄不是 git repo。
            var arguments = ["exec"]
            for path in run.photoPaths { arguments += ["--image", path] }
            arguments += ["--sandbox", "read-only", "--skip-git-repo-check"]
            if let sandbox = run.sandbox { arguments += ["--cd", sandbox.path] }
            arguments.append(prompt)
            return (arguments, nil)

        case "opencode":
            // -f 是陣列選項：**訊息必須排在它前面**，否則訊息會被當成檔案路徑
            // 吃掉（實測會直接回 "File not found: <整段訊息>"）。
            var arguments = ["run", "--dir", run.sandbox?.path ?? FileManager.default.temporaryDirectory.path]
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
            for path in run.photoPaths { arguments.append("@" + path) }
            arguments.append(prompt)
            return (arguments, nil)

        case "cursor":
            // --mode ask 是唯讀模式（不會編輯檔案）；--trust 免掉「信任這個目錄嗎」
            // 的互動確認，在非 TTY 下那個確認會直接讓行程掛住。
            var arguments = ["-p", "--output-format", "json", "--mode", "ask", "--trust"]
            if let sandbox = run.sandbox { arguments += ["--workspace", sandbox.path] }
            arguments.append(prompt)
            return (arguments, nil)

        case "hermes":
            // -z／--oneshot **吃 prompt 當自己的引數**：排在別的旗標後面會得到
            //「expected one argument」而不是一次執行（實測 0.21.3）。
            // --safe-mode 不寫檔、--ignore-rules 不撈使用者的規則檔。
            return (["-z", prompt, "--safe-mode", "--ignore-rules"], nil)

        case "copilot":
            return (["-p", prompt, "-s"], nil)

        case "goose":
            // --no-session 不落 session 檔、-q 只印最終回覆。
            // 非互動模式要靠 extraEnvironment 的 GOOSE_MODE=chat 免掉工具權限確認。
            return (["run", "-t", prompt, "--no-session", "-q"], nil)

        case "amp":
            // prompt 一律走 stdin：argv 只有 -x（amp 的 headless 開關）。
            return (["-x"], prompt)

        case "droid":
            return (["exec", "-o", "json", prompt], nil)

        case "qwen":
            return (["-p", prompt, "--output-format", "text", "--approval-mode", "plan"], nil)

        case "kimi":
            // print 模式會強制自動核准工具呼叫；prompt 本身已要求不要動工具。
            return (["-p", prompt, "--quiet"], nil)

        case "omp":
            return (["-p", "--no-session", "--no-tools", prompt], nil)

        case "prime-agent":
            return (["-p", "--no-tools", "--no-session",
                     "--no-extensions", "--no-skills", prompt], nil)

        case "mistral-vibe":
            return (["-p", prompt, "--output", "text", "--max-turns", "3"], nil)

        case "continue":
            return (["-p", prompt, "--silent"], nil)

        case "aug":
            return (["--print", prompt, "--quiet", "--dont-save-session"], nil)

        case "devin":
            return (["-p", prompt, "--permission-mode", "plan"], nil)

        case "kilo":
            // 同 opencode 家族：訊息排在檔案選項前。
            let directory = run.sandbox?.path ?? FileManager.default.temporaryDirectory.path
            return (["run", "--dir", directory, prompt], nil)

        case "crush":
            return (["run", "-q", prompt], nil)

        case "command-code":
            return (["-p", prompt], nil)

        case "kiro":
            return (["chat", "--no-interactive", prompt], nil)

        default:
            return (["-p", prompt], nil)
        }
    }

    /// CLI 自己的逾時：比我們的 watchdog 早 10 秒收手，讓它吐錯誤而不是被砍。
    private static func innerTimeoutSeconds(_ run: RunContext) -> Int {
        max(Int(run.timeout.components.seconds) - 10, 30)
    }

    /// 前六家（claude…pi）是實測過看圖路徑的，`capabilities` 含 `.vision`；
    /// 其餘一律純文字（`capabilities: []`）——調音顧問與介面翻譯可用，
    /// 光環境顧問會自動跳過它們（能力系統既有行為）。
    ///
    /// **刻意不收**的 CLI，以及理由（收進來只會變成難查的「跑完沒有輸出」）：
    /// - Gemini CLI：Google 2026-06-18 停用個人帳號，官方遷移目標即 agy。
    /// - Codebuff：純 TUI，不認 `-p`。
    /// - MiMo Code：沒有文件化的非互動旗標。
    /// - Trae CN：binary 名稱與文件對不上，且無 JSON 輸出。
    /// - Ante：preview 階段，CLI 介面未文件化。
    /// - Rovo Dev：單則指令有 256 字上限，裝不下顧問的 prompt。
    /// - Aider：stdout 夾 banner，且模型隨金鑰變。
    /// - OpenClaw：要先自己起一個 gateway。
    /// - Cline：只有事件流輸出，沒有終局回覆欄位。
    static let catalog: [KnownCLIEngine] = [
        KnownCLIEngine(
            id: "claude", executableName: "claude", displayName: "Claude Code",
            capabilities: [.vision],
            codec: .jsonEnvelope, photoDelivery: .pathInPrompt,
            pendingIntegration: false, experimental: false,
            authProbe: .command(arguments: ["auth", "status"]),
            readInstruction: "read it with the Read tool before analyzing",
            loginCommand: "claude /login"
        ),
        KnownCLIEngine(
            id: "agy", executableName: "agy", displayName: "Antigravity",
            capabilities: [.vision],
            codec: .responseEnvelope, photoDelivery: .pathInPrompt,
            pendingIntegration: false, experimental: false,
            authProbe: .credentialFile(path: ".gemini/antigravity-cli/antigravity-oauth-token"),
            readInstruction: "read the photo before analyzing",
            loginCommand: "agy"
        ),
        KnownCLIEngine(
            id: "grok", executableName: "grok", displayName: "Grok Build",
            capabilities: [.vision],
            codec: .textEnvelope, photoDelivery: .pathInPrompt,
            pendingIntegration: false, experimental: false,
            authProbe: .credentialFile(path: ".grok/auth.json"),
            readInstruction: "read the photo before analyzing",
            loginCommand: "grok"
        ),
        KnownCLIEngine(
            id: "codex", executableName: "codex", displayName: "Codex CLI",
            capabilities: [.vision],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: false,
            authProbe: .command(arguments: ["login", "status"]),
            readInstruction: "the photo is attached",
            loginCommand: "codex login"
        ),
        KnownCLIEngine(
            id: "opencode", executableName: "opencode", displayName: "OpenCode",
            capabilities: [.vision],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: false,
            authProbe: .credentialFile(path: ".local/share/opencode/auth.json"),
            readInstruction: "the photo is attached",
            loginCommand: "opencode auth login"
        ),
        KnownCLIEngine(
            id: "pi", executableName: "pi", displayName: "Pi",
            capabilities: [.vision],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: false,
            authProbe: .credentialFile(path: ".pi/agent/auth.json"),
            readInstruction: "the photo is attached",
            loginCommand: "pi"
        ),
        KnownCLIEngine(
            id: "cursor", executableName: "cursor-agent", displayName: "Cursor CLI",
            capabilities: [],
            codec: .jsonEnvelope, photoDelivery: .attached,
            pendingIntegration: false, experimental: false,
            authProbe: .command(arguments: ["status", "--format", "json"]),
            readInstruction: "the photo is attached",
            loginCommand: "cursor-agent login"
        ),
        KnownCLIEngine(
            id: "hermes", executableName: "hermes", displayName: "Hermes",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: false,
            authProbe: .command(arguments: ["status"]),
            readInstruction: "the photo is attached",
            loginCommand: "hermes auth login"
        ),
        KnownCLIEngine(
            id: "copilot", executableName: "copilot", displayName: "GitHub Copilot CLI",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            readInstruction: "the photo is attached",
            loginCommand: "copilot"
        ),
        KnownCLIEngine(
            id: "goose", executableName: "goose", displayName: "Goose",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            extraEnvironment: ["GOOSE_MODE": "chat", "GOOSE_DISABLE_SESSION_NAMING": "1"],
            readInstruction: "the photo is attached",
            loginCommand: "goose configure"
        ),
        KnownCLIEngine(
            id: "amp", executableName: "amp", displayName: "Amp",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            authProbe: .environmentKey(names: ["AMP_API_KEY"]),
            readInstruction: "the photo is attached",
            loginCommand: "amp login"
        ),
        KnownCLIEngine(
            id: "droid", executableName: "droid", displayName: "Factory Droid",
            capabilities: [],
            codec: .jsonEnvelope, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            authProbe: .environmentKey(names: ["FACTORY_API_KEY"]),
            readInstruction: "the photo is attached",
            loginCommand: "droid"
        ),
        KnownCLIEngine(
            id: "qwen", executableName: "qwen", displayName: "Qwen Code",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            authProbe: .environmentKey(names: ["OPENAI_API_KEY"]),
            readInstruction: "the photo is attached",
            loginCommand: ""
        ),
        KnownCLIEngine(
            id: "kimi", executableName: "kimi", displayName: "Kimi Code",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            readInstruction: "the photo is attached",
            loginCommand: "kimi"
        ),
        KnownCLIEngine(
            id: "omp", executableName: "omp", displayName: "OMP",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            authProbe: .credentialFile(path: ".omp/agent/auth.json"),
            readInstruction: "the photo is attached",
            loginCommand: "omp"
        ),
        KnownCLIEngine(
            id: "prime-agent", executableName: "prime-agent", displayName: "Prime Agent",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            authProbe: .credentialFile(path: ".prime/agent/auth.json"),
            readInstruction: "the photo is attached",
            loginCommand: "prime-agent"
        ),
        KnownCLIEngine(
            id: "mistral-vibe", executableName: "vibe", displayName: "Mistral Vibe",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            authProbe: .environmentKey(names: ["MISTRAL_API_KEY"]),
            readInstruction: "the photo is attached",
            loginCommand: ""
        ),
        KnownCLIEngine(
            id: "continue", executableName: "cn", displayName: "Continue",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            readInstruction: "the photo is attached",
            loginCommand: "cn login"
        ),
        KnownCLIEngine(
            id: "aug", executableName: "auggie", displayName: "Auggie",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            authProbe: .credentialFile(path: ".augment/session.json"),
            readInstruction: "the photo is attached",
            loginCommand: "auggie login"
        ),
        KnownCLIEngine(
            id: "devin", executableName: "devin", displayName: "Devin",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            authProbe: .command(arguments: ["auth", "status"]),
            readInstruction: "the photo is attached",
            loginCommand: "devin auth login"
        ),
        KnownCLIEngine(
            id: "kilo", executableName: "kilo", displayName: "Kilocode",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            authProbe: .credentialFile(path: ".local/share/kilo/auth.json"),
            readInstruction: "the photo is attached",
            loginCommand: "kilo auth login"
        ),
        KnownCLIEngine(
            id: "crush", executableName: "crush", displayName: "Charm Crush",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            readInstruction: "the photo is attached",
            loginCommand: ""
        ),
        KnownCLIEngine(
            id: "command-code", executableName: "command-code", displayName: "Command Code",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            readInstruction: "the photo is attached",
            loginCommand: ""
        ),
        KnownCLIEngine(
            id: "kiro", executableName: "kiro-cli", displayName: "Kiro",
            capabilities: [],
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            authProbe: .command(arguments: ["whoami"]),
            readInstruction: "the photo is attached",
            loginCommand: "kiro-cli login"
        ),
        KnownCLIEngine(
            id: "openclaude", executableName: "openclaude", displayName: "OpenClaude",
            capabilities: [],
            codec: .jsonEnvelope, photoDelivery: .attached,
            pendingIntegration: false, experimental: true,
            readInstruction: "the photo is attached",
            loginCommand: ""
        ),
    ]
}

/// 引擎偵測與選擇（Registry 最小版；能力旗標等正式化屬接入層 E0）。
/// 掃描順序：SettingsStore 自訂路徑 → PATH → 已知安裝位置。
///
/// 「偵測到」只是第一關：設定頁與所有顧問看的是 `available`——
/// 檔案在、而且**真的跑得起來**（`--version` 5 秒內結束）。同一台機器上
/// 常有半裝好的 CLI（npm 裝了但 runtime 不在、wrapper 指向已刪的版本），
/// 列出它們只會讓使用者選到一個一按分析就失敗的引擎。
@MainActor
@Observable
final class AdviceEngineRegistry {
    /// 執行探測（`--version`）的結果。
    enum ProbeState: Equatable, Sendable {
        /// 還在跑（rescan 剛開始）。
        case pending
        /// 5 秒內結束＝跑得起來；退出碼 0 才有版本字串。
        case ready(version: String?)
        /// 跑不起來或逾時：不列進 `available`。
        case failed
    }

    /// 登入狀態。沒有 `authProbe` 的引擎恆為 `.unknown`，照常可選。
    enum AuthState: Equatable, Sendable {
        case unknown
        case loggedIn
        case notLoggedIn
    }

    struct DetectedEngine: Identifiable {
        let engine: KnownCLIEngine
        let url: URL
        var probe: ProbeState = .pending
        var auth: AuthState = .unknown
        var id: String { engine.id }
        /// 接入未打通的引擎偵測到也不可選。
        var selectable: Bool { !engine.pendingIntegration }
        /// `--version` 的第一行（探測成功且退出碼 0 才有）。
        var version: String? {
            guard case let .ready(version) = probe else { return nil }
            return version
        }
    }

    private(set) var detected: [DetectedEngine] = []

    /// 可以拿來用的引擎：接入打通、而且執行探測沒有失敗。
    /// `.pending` 也算——探測還沒回來就先列出，否則開設定頁會先閃一次空清單。
    var available: [DetectedEngine] {
        detected.filter { $0.selectable && $0.probe != .failed }
    }

    /// 偵測到但跑不起來的（設定頁用一行 caption 交代，不混進可選清單）。
    var unrunnable: [DetectedEngine] {
        detected.filter { $0.probe == .failed }
    }

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
        NSHomeDirectory() + "/.hermes/bin",
        NSHomeDirectory() + "/.factory/bin",
        NSHomeDirectory() + "/bin",
        "/opt/homebrew/bin", "/usr/local/bin",
    ]

    /// 探測（`--version`、auth command）的期限。兩者都只是狀態查詢，
    /// 拖過這個時間就當它壞了——設定頁不該為了一支半裝好的 CLI 卡住。
    nonisolated static let probeTimeout: TimeInterval = 5

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
    /// 的訂閱上，這條線比可用性硬。**也永不**回落到已知未登入的引擎：
    /// 那只是把「未登入」的錯誤換一家報，白等一次逾時。
    func activeEngine(requiring required: Set<KnownCLIEngine.Capability>) -> DetectedEngine? {
        let usable = available.filter {
            isEnabled($0.id) && $0.auth != .notLoggedIn
                && $0.engine.capabilities.isSuperset(of: required)
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
            locate(engine).map { DetectedEngine(engine: engine, url: $0) }
        }
        fetchVersions()
        refreshAuth()
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

    // MARK: - 執行探測

    /// 每家並行 spawn `--version`，各自 5 秒。這同時是「跑不跑得起來」的判準：
    /// 版本字串只是附帶收穫，真正的問題是 npm shim 指向不存在的 runtime、
    /// 或 wrapper 掛在那裡等一個永遠不會來的 TTY。
    private func fetchVersions() {
        for entry in detected {
            let url = entry.url
            let engine = entry.engine
            Task.detached { [weak self] in
                let probe = Self.probeExecutable(at: url, extraEnvironment: engine.extraEnvironment)
                await MainActor.run {
                    guard let self, let index = self.detected.firstIndex(where: { $0.id == engine.id }),
                          self.detected[index].url == url else { return }
                    self.detected[index].probe = probe
                }
            }
        }
    }

    nonisolated static func probeExecutable(
        at url: URL,
        extraEnvironment: [String: String] = [:]
    ) -> ProbeState {
        guard let result = runProbe(at: url, arguments: ["--version"], extraEnvironment: extraEnvironment) else {
            return .failed
        }
        guard result.status == 0 else { return .ready(version: nil) }
        let version = result.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first
        return .ready(version: (version?.isEmpty ?? true) ? nil : version)
    }

    // MARK: - 登入狀態探測

    /// 各引擎並行查登入狀態。失敗（跑不起來、逾時、沒有 probe）一律 `.unknown`：
    /// 探測本身不該變成「不能用這家」的理由。
    private func refreshAuth() {
        for entry in detected {
            guard let probe = entry.engine.authProbe else { continue }
            let url = entry.url
            let engine = entry.engine
            Task.detached { [weak self] in
                let state = Self.evaluateAuth(
                    probe, executable: url, extraEnvironment: engine.extraEnvironment
                )
                await MainActor.run {
                    guard let self, let index = self.detected.firstIndex(where: { $0.id == engine.id }),
                          self.detected[index].url == url else { return }
                    self.detected[index].auth = state
                }
            }
        }
    }

    /// 單一 auth probe 的判定。`home` 與 `environment` 可注入供測試。
    nonisolated static func evaluateAuth(
        _ probe: KnownCLIEngine.AuthProbe,
        executable: URL,
        extraEnvironment: [String: String] = [:],
        home: String = NSHomeDirectory(),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AuthState {
        switch probe {
        case let .command(arguments):
            guard let result = runProbe(
                at: executable, arguments: arguments, extraEnvironment: extraEnvironment
            ) else {
                return .unknown
            }
            return result.status == 0 ? .loggedIn : .notLoggedIn

        case let .credentialFile(path):
            let full = URL(fileURLWithPath: home).appendingPathComponent(path).path
            return FileManager.default.fileExists(atPath: full) ? .loggedIn : .notLoggedIn

        case let .environmentKey(names):
            // App 是 GUI 啟動的，通常拿不到 shell 裡 export 的金鑰；
            // 拿不到就報未登入，設定頁會提示到終端跑登入指令。
            let present = names.contains { (environment[$0]?.isEmpty == false) }
            return present ? .loggedIn : .notLoggedIn
        }
    }

    /// 狀態查詢用的同步 spawn：`probeTimeout` 內沒結束就 terminate 並回 nil。
    /// 逾時當成「跑不起來」——這些指令都該是毫秒級的本機查詢。
    private nonisolated static func runProbe(
        at url: URL,
        arguments: [String],
        extraEnvironment: [String: String]
    ) -> (status: Int32, stdout: String)? {
        let process = Process()
        process.executableURL = url
        process.arguments = arguments
        var environment = CLIProcessRunner.whitelistedEnvironment(
            executableDirectory: url.deletingLastPathComponent().path
        )
        environment.merge(extraEnvironment) { _, new in new }
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(probeTimeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { process.terminate(); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
