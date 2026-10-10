import Foundation

/// Chromium 背景節流偵測（給 browser-use／computer-use 類 agent）。
///
/// 沒帶這兩個 flag 時，被遮住的視窗與背景 renderer 會被 Chrome 節流，
/// 自動化操作會變慢。這裡只判斷、不重啟瀏覽器。
public enum ChromiumThrottlePolicy {
    public static let requiredFlags: [String] = [
        "--disable-backgrounding-occluded-windows",
        "--disable-renderer-backgrounding",
    ]

    /// 主瀏覽器行程（不是 Helper／Renderer）。看 argv[0] 的檔名。
    public static func isBrowserMain(arguments: [String]) -> Bool {
        guard let executable = arguments.first else { return false }
        let name = URL(fileURLWithPath: executable).lastPathComponent.lowercased()
        switch name {
        case "google chrome", "chromium", "chrome":
            return true
        default:
            return false
        }
    }

    public static func hasAntiThrottleFlags(arguments: [String]) -> Bool {
        let flags = Set(arguments)
        return requiredFlags.allSatisfy(flags.contains)
    }

    /// 有 Chrome／Chromium 主行程在跑，且**沒有任何一個**帶齊兩個 flag → 要警告。
    public static func shouldWarn(processArgumentLists: [[String]]) -> Bool {
        var sawMain = false
        var sawProtected = false
        for arguments in processArgumentLists where isBrowserMain(arguments: arguments) {
            sawMain = true
            if hasAntiThrottleFlags(arguments: arguments) {
                sawProtected = true
            }
        }
        return sawMain && !sawProtected
    }

    /// `p_comm` 最多 16 字，先用它過濾再讀 argv。
    public static func isPossibleBrowserComm(_ comm: String) -> Bool {
        let lower = comm.lowercased()
        return lower == "google chrome"
            || lower.hasPrefix("chromium")
            || lower == "chrome"
    }
}
