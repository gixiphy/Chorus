import AppKit

enum WindowArrangementConflicts {
    /// 已知視窗排列工具的 bundle ID（提示共存，非完整偵測）。
    static let knownBundleIDs: Set<String> = [
        "com.crowdcafe.windowmagnet",
        "com.knollsoft.Rectangle",
        "com.knollsoft.Hookshot",
        "com.apple.WindowManager", // 不提示系統本身
    ]

    static func runningThirdPartyNames() -> [String] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard let id = app.bundleIdentifier, knownBundleIDs.contains(id) else { return nil }
            if id == "com.apple.WindowManager" { return nil }
            return app.localizedName ?? id
        }
        .sorted()
    }
}
