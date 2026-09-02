import AppKit
import ChorusCore
import Foundation

/// 設定備份在 iCloud Drive 上的檔案（B8）。
///
/// ```
/// ~/Library/Mobile Documents/com~apple~CloudDocs/Chorus/devices/
///   MacBook Pro.json       ← 這台的。自動備份只寫這一份。
///   Mac mini.json          ← 別台的。要用得在設定頁明確匯入。
/// ```
///
/// **為什麼是直接寫 iCloud Drive**，而不是 `NSUbiquitousKeyValueStore` 或
/// ubiquity container：那兩條路都要 iCloud entitlement，也就要在開發者網站
/// 幫 App ID 開 iCloud、要 provisioning profile、打包腳本要跟著檢查它的
/// 到期日。Chorus 不沙盒，直接寫 CloudDocs **一行 entitlement 都不用改**，
/// 而且檔案就躺在使用者自己的 iCloud Drive 裡看得到、打得開。
/// （架構參考使用者的另一個專案 Foldwall 0.7.0，MIT；只參考做法不搬碼。）
@MainActor
final class CloudBackupFiles {
    /// `Chorus/devices/` 的上一層。`nil` ＝ iCloud Drive 沒開，整個功能停用。
    let root: URL?

    /// 這台的顯示名（檔名用它）與長期身分。
    let deviceName: String
    let deviceID: String

    /// 撞名時算過一次就好（判斷依據是檔案裡的 `deviceID`，不是檔名）。
    private var cachedFileName: String?

    init(root: URL?, deviceName: String, deviceID: String) {
        self.root = root
        self.deviceName = deviceName
        self.deviceID = deviceID
    }

    /// 正式路徑：iCloud Drive 沒登入／沒開啟時那個目錄不存在，回 nil。
    static func defaultRoot() -> URL? {
        let drive = URL.homeDirectory.appending(path: "Library/Mobile Documents/com~apple~CloudDocs")
        guard FileManager.default.fileExists(atPath: drive.path(percentEncoded: false)) else {
            return nil
        }
        return drive.appending(path: "Chorus")
    }

    var isAvailable: Bool { root != nil }

    var devicesDirectory: URL? { root?.appending(path: "devices") }

    /// 使用者看得懂的路徑，設定頁顯示用。
    var displayPath: String {
        guard let root else { return String(localized: "iCloud Drive 未啟用") }
        let home = URL.homeDirectory.path
        return root.path.hasPrefix(home) ? "~" + root.path.dropFirst(home.count) : root.path
    }

    /// 這台的備份檔。
    ///
    /// 檔名用**機器名**而不是 id：這些檔案就攤在使用者的 iCloud Drive 裡，
    /// 一排 UUID 檔名等於白放。只有撞名（兩台都叫 MacBook Pro）時才退回
    /// 帶 id 後綴。
    var deviceURL: URL? {
        guard let devicesDirectory else { return nil }
        if let cachedFileName { return devicesDirectory.appending(path: cachedFileName) }
        let plain = Self.sanitize(deviceName) + ".json"
        let candidate = devicesDirectory.appending(path: plain)
        let name: String
        if let occupant = decode(at: candidate), occupant.deviceID != deviceID, !occupant.deviceID.isEmpty {
            name = Self.sanitize(deviceName) + "-" + deviceID.prefix(8) + ".json"
        } else {
            name = plain
        }
        cachedFileName = name
        return devicesDirectory.appending(path: name)
    }

    /// 檔名裡不能有路徑分隔符；`:` 在 Finder 顯示時會被轉成 `/`，一起擋掉。
    /// 開頭的點會讓檔案在 Finder 裡隱形。
    private static func sanitize(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned.isEmpty ? "Mac" : cleaned
    }

    // MARK: - 讀寫

    @discardableResult
    func write(_ backup: DeviceBackup, to url: URL? = nil) throws -> URL {
        guard let target = url ?? deviceURL else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try BackupCodec.encode(backup).write(to: target, options: .atomic)
        return target
    }

    func decode(at url: URL) -> DeviceBackup? {
        guard let data = try? Data(contentsOf: url) else {
            // iCloud 上可能只放了佔位符（`.icloud`）。請系統下載——這是非同步的，
            // 所以這一次仍然讀不到，下次進設定頁再試。
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            return nil
        }
        return try? BackupCodec.decode(DeviceBackup.self, from: data)
    }

    var lastBackupDate: Date? {
        guard let deviceURL else { return nil }
        return (try? deviceURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// `devices/` 底下每一份，新到舊。**解不開的略過**——那可能是使用者自己
    /// 丟進去的東西，不該讓整份清單消失。
    func scan() -> [BackupFile] {
        guard let devicesDirectory,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: devicesDirectory, includingPropertiesForKeys: nil)
        else { return [] }
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let backup = decode(at: url) else { return nil }
                return BackupFile(
                    url: url,
                    deviceName: backup.deviceName,
                    deviceID: backup.deviceID,
                    savedAt: backup.savedAt,
                    isSelf: backup.deviceID == deviceID
                )
            }
            .sorted { $0.savedAt > $1.savedAt }
    }

    func revealInFinder() {
        guard let root else { return }
        if FileManager.default.fileExists(atPath: root.path(percentEncoded: false)) {
            NSWorkspace.shared.activateFileViewerSelecting([root])
        } else {
            NSWorkspace.shared.open(root.deletingLastPathComponent())
        }
    }
}

/// iCloud 上某一台留下的備份。設定頁用它列出「可以匯入誰的」。
struct BackupFile: Identifiable, Equatable, Sendable {
    var id: String { url.path }
    var url: URL
    var deviceName: String
    var deviceID: String
    var savedAt: Date
    /// 這一份是不是這台自己寫的（決定匯入時要不要過濾綁機欄位）。
    var isSelf: Bool
}
