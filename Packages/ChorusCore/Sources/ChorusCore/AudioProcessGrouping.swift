import Foundation

/// 音訊行程 → 選單「各 App 音量」可列出的 App 的歸組規則（純函式）。
///
/// 系統回報的 audio process 遠多於使用者認得的「App」：瀏覽器的 helper
/// 行程有自己的 bundle id（`com.vivaldi.Vivaldi.helper`），daemon
/// （`audiomxd`、`assistantd`…）也都有 bundle id。直接列出來有兩個問題：
/// 清單塞滿使用者不認得的東西；更嚴重的是**聲音實際上從 helper 出來**，
/// 依主 App bundle 建的 tap 抓不到它，而 helper 又以獨立一列出現——
/// 兩列控制同一路音訊，互相打架。
///
/// 規則：helper 依 bundle id 前綴歸到它的主 App；不是 App、也歸不進
/// 任何 App 的行程（daemon）不列。Apple 自家的 accessory（控制中心、
/// 功能列）也不列——它們的提示音由「提示音音量」那條滑桿負責。
public enum AudioProcessGrouping {
    /// 行程的身分，由呼叫端在讀清單時判定（App 端用
    /// `NSRunningApplication.activationPolicy`；測試直接指定）。
    public enum Kind: Sendable, Equatable {
        /// 一般 App（有 Dock 圖示）。
        case regularApp
        /// 選單列／背景 App（accessory）。
        case accessoryApp
        /// 其餘：helper、daemon、查不到的行程。
        case other
    }

    /// `bundleID` 應歸到哪個 App root。
    ///
    /// - regular App（有 Dock 圖示）永遠是自己的 root——Safari 網頁 App
    ///   （`com.apple.Safari.WebApp.…`）是獨立 App，不因前綴被併進 Safari。
    /// - 其餘（accessory、helper、daemon）**先找爸媽再認自己**：取最長的
    ///   App bundle `R`（`R ≠ bundleID`）使 `bundleID` 以 `R + "."` 開頭。
    ///   順序不能反過來——Chromium／Electron 的 helper 在 Info.plist 標
    ///   `LSUIElement`，系統回報它們是 accessory「App」；先認自己的話
    ///   helper 全部自成一列，而主 App 的 tap 也不會把它算進成員
    ///   （聲音正是從 helper 出來的，等於整個 per-app 調整無效）。
    /// - 找不到爸媽、自己也不是 App → `nil`（不可列）。
    public static func rootBundleID(
        for bundleID: String, appKinds: [String: Kind]
    ) -> String? {
        if appKinds[bundleID] == .regularApp { return bundleID }
        // 這裡是「每個行程 × 每個執行中 App」的內圈（選單描繪與每輪對帳
        // 都會走），不做 `$0 + "."` 串接——那是每個 key 一次字串配置
        var parent: String?
        var parentLength = 0
        for candidate in appKinds.keys {
            let length = candidate.count
            guard length < bundleID.count, length > parentLength,
                  bundleID.hasPrefix(candidate),
                  bundleID[bundleID.index(bundleID.startIndex, offsetBy: length)] == "."
            else { continue }
            parent = candidate
            parentLength = length
        }
        if let parent { return parent }
        return appKinds[bundleID] != nil ? bundleID : nil
    }

    /// 這個 root 該不該出現在清單上。Apple 自家的 accessory／daemon
    /// 不列（提示音已有專屬滑桿），第三方 accessory（選單列播放器）要列。
    public static func isListable(kind: Kind, bundleID: String) -> Bool {
        switch kind {
        case .regularApp: true
        case .accessoryApp: !bundleID.hasPrefix("com.apple.")
        case .other: false
        }
    }
}
