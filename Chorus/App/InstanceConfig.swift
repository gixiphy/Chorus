import Foundation

/// 解析 `--instance <name>` 啟動參數，讓同一台 Mac 能跑多份 Chorus 做同步測試。
/// 不同 instance 使用獨立的 UserDefaults suite、Keychain service 與 peer ID。
struct InstanceConfig: Sendable {
    /// nil 表示預設 instance（正常使用情境）。
    let name: String?

    static let current = InstanceConfig(arguments: ProcessInfo.processInfo.arguments)

    /// 同步 listener 的固定 port（未指定時自動分配並靠 Bonjour 發現）。
    /// mDNS 被擋（AP client isolation、區域網路權限異常）時搭配手動端點使用。
    let syncListenPort: UInt16?
    /// 配對 listener 的固定 port。
    let pairListenPort: UInt16?
    /// 模擬光感器（僅 DEBUG build 生效；無感器機器與同機 E2E 測試用）。
    let fakeALS: Bool
    /// 停用光感器（僅 DEBUG build 生效；在有感器的機器上模擬桌機 follower）。
    let disableALS: Bool
    /// tap 引擎用 FakeTapBackend（僅 DEBUG；E2E 不需權限與真硬體）。
    let fakeTaps: Bool
    /// 設定備份的根目錄覆寫（B8 的 E2E 用）。給了就不碰真的 iCloud Drive
    /// ——同機雙實例測試不該把東西寫進使用者的雲端硬碟。
    let cloudRoot: String?

    init(arguments: [String]) {
        func value(after flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
            return arguments[index + 1]
        }
        name = value(after: "--instance")
        syncListenPort = value(after: "--listen-port").flatMap(UInt16.init)
        pairListenPort = value(after: "--pair-port").flatMap(UInt16.init)
        fakeALS = arguments.contains("--fake-als")
        disableALS = arguments.contains("--no-als")
        fakeTaps = arguments.contains("--fake-taps")
        cloudRoot = value(after: "--cloud-root")
    }

    private static let baseIdentifier = Bundle.main.bundleIdentifier ?? "com.hermes.Chorus"

    /// UserDefaults suite；預設 instance 用 standard。
    var defaults: UserDefaults {
        guard let name else { return .standard }
        return UserDefaults(suiteName: "\(Self.baseIdentifier).instance-\(name)") ?? .standard
    }

    /// Keychain service 名稱。
    var keychainService: String {
        guard let name else { return Self.baseIdentifier }
        return "\(Self.baseIdentifier).instance-\(name)"
    }

    /// 對外顯示的裝置名稱（Bonjour TXT 用）。
    var deviceDisplayName: String {
        let host = Host.current().localizedName ?? "Mac"
        guard let name else { return host }
        return "\(host) (\(name))"
    }

    /// 這個 instance 的 peer ID（per-install UUID，存在該 instance 的 defaults）。
    var peerID: String {
        let key = "chorus.peerID"
        let defaults = defaults
        if let existing = defaults.string(forKey: key) { return existing }
        let fresh = UUID().uuidString
        defaults.set(fresh, forKey: key)
        return fresh
    }
}
