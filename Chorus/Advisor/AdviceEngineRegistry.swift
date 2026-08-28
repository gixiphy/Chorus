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
    let id: String
    let executableName: String
    let displayName: String
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
            codec: .jsonEnvelope, photoDelivery: .pathInPrompt,
            pendingIntegration: false, experimental: false, supportsModelSelection: true,
            modelHint: "別名 opus／sonnet／fable，或完整名稱如 claude-opus-5",
            readInstruction: "用 Read 工具讀取後再分析",
            loginCommand: "claude /login"
        ),
        KnownCLIEngine(
            id: "agy", executableName: "agy", displayName: "Antigravity",
            codec: .responseEnvelope, photoDelivery: .pathInPrompt,
            pendingIntegration: false, experimental: false, supportsModelSelection: true,
            modelHint: "slug，如 gemini-3.1-pro-high、claude-sonnet-4-6",
            readInstruction: "請先讀取照片再分析",
            loginCommand: "agy"
        ),
        KnownCLIEngine(
            id: "grok", executableName: "grok", displayName: "Grok Build",
            codec: .textEnvelope, photoDelivery: .pathInPrompt,
            pendingIntegration: false, experimental: false, supportsModelSelection: true,
            modelHint: "模型 ID（見 grok 的模型清單）",
            readInstruction: "請先讀取照片再分析",
            loginCommand: "grok"
        ),
        KnownCLIEngine(
            id: "codex", executableName: "codex", displayName: "Codex CLI",
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: false, supportsModelSelection: true,
            modelHint: "模型名稱，如 gpt-5.6-terra",
            readInstruction: "照片已附加",
            loginCommand: "codex login"
        ),
        KnownCLIEngine(
            id: "opencode", executableName: "opencode", displayName: "OpenCode",
            codec: .plainStdout, photoDelivery: .attached,
            pendingIntegration: false, experimental: false, supportsModelSelection: true,
            modelHint: "provider/model 格式，如 anthropic/claude-sonnet-4-6",
            readInstruction: "照片已附加",
            loginCommand: "opencode auth login"
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

    init(settings: SettingsStore) {
        self.settings = settings
        rescan()
    }

    /// 目前選定且可用的引擎；選定的不可用時回落 claude → 任一可選引擎。
    var activeEngine: DetectedEngine? {
        let selectable = detected.filter(\.selectable)
        if let chosen = selectable.first(where: { $0.id == settings.advisorEngineID }) {
            return chosen
        }
        return selectable.first { $0.id == "claude" } ?? selectable.first
    }

    func rescan() {
        detected = KnownCLIEngine.catalog.compactMap { engine in
            locate(engine).map { DetectedEngine(engine: engine, url: $0, version: nil) }
        }
        fetchVersions()
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
