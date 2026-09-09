import Foundation

/// 一個 AI agent session 的活動跡證（M9-2 Agent 模式）。
///
/// 「這台機器上有 agent 在工作嗎」不能用行程判斷，也不能用 CPU 判斷：
/// - 行程在 ≠ 在工作——`claude` 停在 prompt 等你打字時行程一樣在，
///   綁行程等於無限期長亮。
/// - CPU 也分不開——實測工作中的 session 六秒只吃 0.22 秒 CPU（0.04 核），
///   閒置的是 0.03 秒（0.01 核）。agent 大部分時間在等模型回應，根本不燒 CPU，
///   兩者差距小到訂不出門檻。
///
/// 分得開的是 **session log 有沒有在長**：工作中每幾秒 append 一次，
/// 停在 prompt 就完全不寫。所以樣本只有「哪個 session、最後寫入時間」，
/// 不讀檔案內容。
public struct AgentSessionSample: Sendable, Equatable, Identifiable, Hashable {
    /// log 檔路徑。同一支 agent 同時開多個 session 要能各自計算，用路徑當身分。
    public let id: String
    /// 來源顯示名稱（"Claude Code"／"Codex"），選單說明用。
    public let engine: String
    /// 最後寫入時間。**是 wall clock 不是 uptime**：檔案 mtime 只有 wall clock，
    /// 沒得選。使用者改系統時鐘會讓當下這一輪誤判，下一輪取樣就恢復。
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
