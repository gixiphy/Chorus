import Foundation

/// 解析 `--instance <name>` 啟動參數，讓同一台 Mac 能跑多份 Chorus 做同步測試。
/// 不同 instance 使用獨立的 UserDefaults suite、Keychain service 與 peer ID。
struct InstanceConfig: Sendable {
    /// nil 表示預設 instance（正常使用情境）。
    let name: String?

    static let current = InstanceConfig(arguments: ProcessInfo.processInfo.arguments)

    init(arguments: [String]) {
        if let index = arguments.firstIndex(of: "--instance"), index + 1 < arguments.count {
            name = arguments[index + 1]
        } else {
            name = nil
        }
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
