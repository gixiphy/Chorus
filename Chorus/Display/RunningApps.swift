import AppKit

/// 「這個 App 執行中才長亮」用得到的執行中 App 查詢（M9）。
///
/// 只讀 `NSWorkspace`，不需要任何權限——App 清單、名稱與圖示都是公開資訊。
/// 沒有自己的快取：呼叫點都是使用者互動（開選單）或 App 啟動／結束事件，
/// 頻率低到不值得為它維護一份會過期的狀態。
enum RunningApps {
    /// 可以拿來綁定的 App。
    struct Option: Identifiable, Hashable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// 目前執行中的所有 bundle ID（含背景服務——綁定後對方若是背景常駐，
    /// 條件就一直成立，這是使用者自己選的）。
    static func bundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    /// 選單要列的 App：只收有 Dock 圖示的（`.regular`），
    /// 濾掉 Chorus 自己（綁自己等於無限期，選單已經有那一項）。
    static func options() -> [Option] {
        let own = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .compactMap { app -> Option? in
                guard app.activationPolicy == .regular,
                      let bundleID = app.bundleIdentifier,
                      bundleID != own,
                      seen.insert(bundleID).inserted
                else { return nil }
                return Option(bundleID: bundleID, name: app.localizedName ?? displayName(for: bundleID))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 顯示名稱。行程在就用行程的；不在就查安裝位置；都查不到就退回
    /// bundle id 的最後一段（總比一串反轉網域好認）。
    static func displayName(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }), let name = running.localizedName {
            return name
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }
}
