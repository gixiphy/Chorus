import Foundation

/// 一份 AI agent 的活動跡證（M9-2 Agent 模式）。
///
/// 「這台機器上有 agent 在工作嗎」不能用行程在不在判斷——`claude` 停在 prompt
/// 等你打字時行程一樣在，綁行程等於無限期長亮。分得開的有兩種跡證：
///
/// 1. **session log 有沒有在長**：工作中每幾秒 append 一次，停在 prompt 就完全不寫。
///    只讀目錄列表與 mtime，不開檔、不讀內容（掃描見 `AgentRegistry`）。
/// 2. **有終端機的行程樹有沒有在燒 CPU**：本機 30 秒視窗實測，claude 工作中 6.4%、
///    cursor-agent 工作中 13.6%，claude 停在 prompt 只有 0.8%；沒有終端機的常駐 helper
///    （`agy`、`claude --chrome-native-host`）是 0.7% 與 0。取「30 秒 ≥ 0.5 秒」當線，
///    加上「必須有 TTY」就分得開（判定見 `AgentProcessActivityPlanner`）。
///    這一層是為了涵蓋沒有全域 session log 的 agent 與使用者自訂的 CLI。
///
/// （早期的註解說 CPU 分不開，那次量的是單一行程、6 秒視窗——換成整棵樹、30 秒視窗
/// 之後兩群差了一個數量級，結論不成立。）
public struct AgentSessionSample: Sendable, Equatable, Identifiable, Hashable {
    /// 身分：log 樣本是檔案路徑，行程樣本是 `pid:<n>`。
    /// 同一支 agent 同時開多個 session／跑多棵行程樹要能各自計算，所以身分不是 engine。
    public let id: String
    /// 來源顯示名稱（"Claude Code"／"Codex"），選單說明用。
    public let engine: String
    /// 最後一次活動跡證的時刻：log 樣本是檔案 mtime，行程樣本是最後一次判定有活動的取樣時間。
    ///
    /// **是 wall clock 不是 uptime**：檔案 mtime 只有 wall clock，沒得選。
    /// 使用者改系統時鐘會讓當下這一輪誤判，下一輪取樣就恢復。
    public let lastWrite: Date

    public init(id: String, engine: String, lastWrite: Date) {
        self.id = id
        self.engine = engine
        self.lastWrite = lastWrite
    }
}

public enum AgentActivityPlanner {
    /// 多久沒寫 log 就當這個 session 收工了。
    ///
    /// 5 分鐘抓的是「一次模型回應 ＋ 一個長 tool call」的上限——中間確實會有
    /// 一兩分鐘不寫檔，門檻太短會在 agent 還在跑時把 assertion 放掉。
    /// 太長的代價只是收工後多醒幾分鐘，比機器睡著中斷 agent 便宜得多。
    public static let defaultGraceSeconds: Double = 300

    /// 目前算「工作中」的 session，最近寫入的排前面（選單只秀第一個的來源名）。
    ///
    /// mtime 落在未來（改過系統時鐘、或從別台機器同步過來的檔）一律當成剛寫過：
    /// 寧可多醒一輪，也不要因為時鐘歪掉就讓機器在 agent 跑到一半時睡著。
    public static func workingSessions(
        _ samples: [AgentSessionSample],
        now: Date,
        graceSeconds: Double = defaultGraceSeconds
    ) -> [AgentSessionSample] {
        samples
            .filter { now.timeIntervalSince($0.lastWrite) < graceSeconds }
            .sorted { $0.lastWrite > $1.lastWrite }
    }
}
