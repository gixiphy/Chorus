import ChorusCore
import Foundation

/// 光環境顧問的引擎接縫：單發、需 vision（設計文件 §2 接縫 1）。
/// 實作：CLIAdviceProvider（正式）、FakeAdviceProvider（DEBUG/測試）。
/// 回傳值未經 sanitized —— LightingAdvisor 一律再過 `sanitized(for:)`。
protocol LightingAdviceProvider: Sendable {
    /// `photos`：第一張是配置圖背景照，其餘為補充視角（多角度／不同照明情境）；
    /// 每張可帶使用者手寫的照明情境標註。
    func advise(photos: [LabeledPhoto], context: AdviceContext) async throws -> LightingAdvice
}

/// 引擎層錯誤 → UI 訊息的映射來源（設計文件 §3 錯誤映射）。
enum AdviceError: Error {
    /// 選定引擎的執行檔不存在（UI：開設定頁、安裝指引）。
    case engineNotFound(engineID: String)
    /// CLI 回報未登入／未認證（UI：請先在終端完成登入）。
    case notLoggedIn(engineID: String)
    /// 逾時（預設 120s）後已終止子行程。
    case timedOut
    /// 非零退出且非認證問題；帶 stderr 摘要。
    case processFailed(status: Int32, stderr: String)
    /// 重試一次後仍無法解析；帶模型原始回覆供顯示與回報。
    case decodeFailed(raw: String)

    var userMessage: String {
        switch self {
        case let .engineNotFound(engineID):
            "未找到 \(engineID) CLI，請確認已安裝（設定 → 分析引擎）"
        case let .notLoggedIn(engineID):
            "\(engineID) 未登入或憑證已失效，請在終端重新登入後再試"
        case .timedOut:
            "分析逾時，可重試"
        case let .processFailed(status, stderr):
            stderr.isEmpty
                ? "分析失敗（退出碼 \(status)），CLI 未提供錯誤訊息"
                : "分析失敗（退出碼 \(status)）：\(stderr.prefix(200))"
        case let .decodeFailed(raw):
            "模型回覆無法解析：\(raw.prefix(300))"
        }
    }

    /// UI 可附帶的協助動作（錯誤訊息旁的按鈕）。
    enum Assist: Equatable {
        /// 複製登入指令到剪貼簿，讓使用者到終端貼上執行。
        case copyLoginCommand(String)
        /// 開啟設定 → 分析引擎。
        case openEngineSettings
    }

    var assist: Assist? {
        switch self {
        case let .notLoggedIn(engineID):
            .copyLoginCommand(Self.loginCommand(for: engineID))
        case .engineNotFound:
            .openEngineSettings
        case .timedOut, .processFailed, .decodeFailed:
            nil
        }
    }

    private static func loginCommand(for engineID: String) -> String {
        switch engineID {
        case "claude": "claude /login"
        case "codex": "codex login"
        default: engineID
        }
    }
}
