import Foundation

/// `chorus doctor` 拿不到報告時的各種情況。文字與 JSON 兩種輸出、結束碼都在這裡定義，
/// CLI 只負責判斷是哪一種——`--json` 的每條路徑因此都保證是合法 JSON。
public enum DoctorFailure: Sendable, Equatable {
    case notConfigured(String)
    case unauthorized(String)
    case unreachable(port: UInt16)
    case timedOut(port: UInt16)
    case mainThreadStalled(health: String?)
    case unsupportedApp
    case unreadableReport(String)
    case http(status: Int, body: String)

    public var exitCode: Int32 {
        switch self {
        case .notConfigured, .unauthorized: 3
        case .unreachable, .timedOut: 4
        case .mainThreadStalled, .unsupportedApp, .unreadableReport, .http: 1
        }
    }

    var kind: String {
        switch self {
        case .notConfigured: "notConfigured"
        case .unauthorized: "unauthorized"
        case .unreachable: "unreachable"
        case .timedOut: "timedOut"
        case .mainThreadStalled: "mainThreadStalled"
        case .unsupportedApp: "unsupportedApp"
        case .unreadableReport: "unreadableReport"
        case .http: "http"
        }
    }

    var title: String {
        switch self {
        case .notConfigured, .unauthorized, .http: "自動化介面"
        case .unreachable, .timedOut: "連線"
        case .mainThreadStalled, .unreadableReport: "App 回應"
        case .unsupportedApp: "Chorus 版本"
        }
    }

    var message: String {
        switch self {
        case let .notConfigured(detail), let .unauthorized(detail): detail
        case let .unreachable(port): "連不上 127.0.0.1:\(port)。"
        case let .timedOut(port): "連到 127.0.0.1:\(port) 但等不到回應。"
        case .mainThreadStalled: "Chorus 正在執行，但主執行緒超過 10 秒沒有回應。"
        case .unsupportedApp: "這個版本的 Chorus 還沒有 /v1/doctor。"
        case let .unreadableReport(detail): "無法解讀 Chorus 回傳的報告（\(detail)）。"
        case let .http(status, body): "HTTP \(status) \(body)"
        }
    }

    var remedy: String {
        switch self {
        case .notConfigured: "到 Chorus 設定頁開啟「自動化介面」後再執行 chorus doctor。"
        case .unauthorized: "到設定頁重新產生 token，或檢查 CHORUS_TOKEN。"
        case .unreachable:
            "確認 Chorus 正在執行、設定頁的「自動化介面」已開啟，且 port 與 ~/.config/chorus/config.json 一致"
                + "（介面關閉後設定檔可能還留著）。"
        case .timedOut: "等一分鐘再試；若持續發生，結束並重新開啟 Chorus。"
        case .mainThreadStalled: "等一分鐘再試；若持續發生，結束並重新開啟 Chorus，再到設定頁按「匯出診斷包…」。"
        case .unsupportedApp: "更新 Chorus 後再試。"
        case .unreadableReport: "CLI 與 App 版本可能不一致：到設定頁重新安裝 CLI，或更新 Chorus。"
        case .http: "再執行一次；若持續發生，到設定頁按「匯出診斷包…」回報。"
        }
    }

    public func render(json: Bool) -> String {
        if json { return renderJSON() }
        var lines = ["✗ \(title) — \(message)"]
        if case let .mainThreadStalled(health?) = self { lines.append("   健康快照：\(health)") }
        lines.append("   → \(remedy)")
        return lines.joined(separator: "\n")
    }

    private func renderJSON() -> String {
        var error: [String: Any] = ["kind": kind, "message": message, "remedy": remedy]
        if case let .mainThreadStalled(health?) = self {
            // 健康快照本身是 JSON 就嵌成物件，jq 才拿得到裡面的欄位
            error["health"] = (try? JSONSerialization.jsonObject(with: Data(health.utf8))) ?? health
        }
        let object: [String: Any] = ["ok": false, "exitCode": Int(exitCode), "error": error]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return #"{"ok":false,"exitCode":\#(exitCode)}"#
        }
        return String(decoding: data, as: UTF8.self)
    }
}
