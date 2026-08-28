import ChorusCore
import Foundation
import Observation

/// 已知 CLI 目錄的一筆（DESIGN-ai-provider-layer §0.1）。
/// 偵測到誰就在設定頁列誰；預設引擎＝claude（存在時）。
struct KnownCLIEngine: Identifiable, Sendable {
    let id: String
    let executableName: String
    let displayName: String
    let codec: AdviceOutputCodec
    /// 接入尚未打通（接入層 E1 處理）前標「待接入」不可選。
    /// agy 現況（1.1.7 實測）：pipe 輸出正常（舊 PTY bug 已修），
    /// 但 headless 權限規則下 read_file 讀圖拿不到輸出，vision 流程未通。
    let pendingIntegration: Bool
    /// headless／讀圖行為尚未驗證（codex）：可選，標「實驗性」。
    let experimental: Bool
    /// 給 prompt 的照片讀取措辭（claude 有 Read 工具，其他用通用措辭）。
    let readInstruction: String

    /// 單發呼叫的參數與 prompt 傳遞方式。
    /// claude 走 stdin（prompt 長，避開 argv）；其餘以參數帶 prompt。
    func invocation(prompt: String) -> (arguments: [String], stdin: String?) {
        switch id {
        case "claude":
            (["-p", "--output-format", "json", "--allowedTools", "Read"], prompt)
        case "codex":
            (["exec", prompt], nil)
        default:
            (["-p", prompt], nil)
        }
    }

    /// Gemini CLI 不在目錄中：Google 已於 2026-06-18 停用（個人帳號停止服務），
    /// 官方遷移目標即 Antigravity CLI（agy）。
    static let catalog: [KnownCLIEngine] = [
        KnownCLIEngine(
            id: "claude", executableName: "claude", displayName: "Claude Code",
            codec: .jsonEnvelope, pendingIntegration: false, experimental: false,
            readInstruction: "用 Read 工具讀取後再分析"
        ),
        KnownCLIEngine(
            id: "agy", executableName: "agy", displayName: "Antigravity",
            codec: .plainStdout, pendingIntegration: true, experimental: false,
            readInstruction: "請先讀取照片再分析"
        ),
        KnownCLIEngine(
            id: "codex", executableName: "codex", displayName: "Codex CLI",
            codec: .plainStdout, pendingIntegration: false, experimental: true,
            readInstruction: "請先讀取照片再分析"
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
