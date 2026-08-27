import ChorusCore
import Foundation

/// 光環境顧問的引擎接縫：單發、需 vision（設計文件 §2 接縫 1）。
/// 實作：CLIAdviceProvider（正式）、FakeAdviceProvider（DEBUG/測試）。
/// 回傳值未經 sanitized —— LightingAdvisor 一律再過 `sanitized(for:)`。
protocol LightingAdviceProvider: Sendable {
    func advise(photoPath: String, context: AdviceContext) async throws -> LightingAdvice
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
            "請先在終端執行一次 \(engineID) 完成登入"
        case .timedOut:
            "分析逾時，可重試"
        case let .processFailed(status, stderr):
            "分析失敗（退出碼 \(status)）：\(stderr.prefix(200))"
        case let .decodeFailed(raw):
            "模型回覆無法解析：\(raw.prefix(300))"
        }
    }
}
