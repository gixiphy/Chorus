import AppKit
import ChorusCore
import CoreAudio
import Foundation
import Observation

/// 系統 audio process 物件的清單（`kAudioHardwarePropertyProcessObjectList`）。
/// per-app 音量的「App 清單」與健康判讀的「誰在發聲」都從這裡來。
///
/// 選單列出的不是行程而是**歸組後的 App**（`AudioProcessGrouping`）：
/// helper 歸主 App、daemon 不列。tap 也要以整組成員描述，否則聲音
/// 從 helper 出來時主 App 的 tap 抓不到。
@MainActor
@Observable
final class AudioProcessRegistry {
    struct Entry: Identifiable, Sendable, Equatable {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        let name: String
        var isAudible: Bool
        var kind: AudioProcessGrouping.Kind = .regularApp
        var id: AudioObjectID { objectID }
    }

    private(set) var processes: [Entry] = []
    /// 執行中 App 的身分（bundleID → kind）。歸組的 App root 從這裡來，
    /// 不能只看音訊行程——瀏覽器常常只有 helper 有音訊行程，主 App 沒有。
    private(set) var appKinds: [String: AudioProcessGrouping.Kind] = [:]
    /// TestHooks 注入 fake 清單後鎖住，真實 refresh 不再覆蓋。
    private(set) var isFake = false
    /// 行程清單變動（helper 出現／消失）時的回呼——TapEngine 要重新
    /// 對帳，讓 tap 描述涵蓋新出現的成員。
    @ObservationIgnored var onProcessesChanged: (@MainActor () -> Void)?
    @ObservationIgnored private var listeningForChanges = false

    /// Chorus 自己的 process object（回音紀律：探測的排除清單至少要有它）。
    /// 查一次就快取——它在每輪對帳（含每一格音量滑桿）都被讀，每次都打
    /// HAL 翻譯是浪費。coreaudiod 重啟會讓 object 失效，所以 `refresh()`
    /// （行程清單一變就會跑）順手清掉快取。
    var ownProcessObjectID: AudioObjectID? {
        if let cachedOwnProcessObjectID { return cachedOwnProcessObjectID }
        cachedOwnProcessObjectID = translate(pid: ProcessInfo.processInfo.processIdentifier)
        return cachedOwnProcessObjectID
    }
    @ObservationIgnored private var cachedOwnProcessObjectID: AudioObjectID?

    /// 有任何**非自己**的來源正在發聲（健康判讀的 audible 訊號）。
    var anyOtherProcessAudible: Bool {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        return processes.contains { $0.isAudible && $0.pid != ownPid }
    }

    /// 選單列 per-app 清單的來源：歸組後可列出的 App root，依顯示名稱排序。
    /// 不含 Chorus 自己（回音紀律：我們不 tap 自己）。
    var listableApps: [String] {
        let ownBundle = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return processes
            .compactMap { rootBundleID(of: $0) }
            .filter { root in
                root != ownBundle
                    && AudioProcessGrouping.isListable(kind: appKinds[root] ?? .other, bundleID: root)
                    && seen.insert(root).inserted
            }
            // 名稱先解一次再排序——比較器裡每比一次就查一次 displayName
            // 的話，已退出的 App 每次比較都是一趟 LaunchServices
            .map { (id: $0, name: displayName(bundleID: $0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map(\.id)
    }

    /// 這個 App（含歸它的 helper）有沒有正在發聲。
    func isGroupAudible(bundleID: String) -> Bool {
        processes.contains { $0.isAudible && rootBundleID(of: $0) == bundleID }
    }

    /// tap 描述要涵蓋的 bundle：root ＋ 目前觀察到歸它的 helper。
    /// 少了 helper，瀏覽器類 App 的 tap 會抓不到實際發聲的行程。
    func memberBundleIDs(bundleID: String) -> [String] {
        var members = [bundleID]
        for entry in processes {
            guard let member = entry.bundleID, member != bundleID,
                  rootBundleID(of: entry) == bundleID, !members.contains(member)
            else { continue }
            members.append(member)
        }
        return members
    }

    func entry(bundleID: String) -> Entry? {
        processes.first { $0.bundleID == bundleID }
    }

    /// 這些 App root 名下的 process object（含 helper）。裝置級全域 tap
    /// 要拿它來排除已被 per-app tap 捕獲的行程——每一路音訊只處理一次
    /// （DESIGN §2.2）。漏掉 helper ＝ 那一路被處理兩次。
    func processObjectIDs(bundleIDs: Set<String>) -> [AudioObjectID] {
        processes
            .filter { entry in
                entry.bundleID.map(bundleIDs.contains) == true
                    || rootBundleID(of: entry).map(bundleIDs.contains) == true
            }
            .map(\.objectID)
    }

    /// 歸組結果快取（bundleID → root）。歸組是 O(執行中 App 數) 的前綴
    /// 比對，而 listable／audible／member 每次查詢都要它——輸入
    /// （processes、appKinds）只在 refresh／injectFake 變，就在那裡清。
    @ObservationIgnored private var rootCache: [String: String??] = [:]

    private func rootBundleID(of entry: Entry) -> String? {
        guard let bundleID = entry.bundleID else { return nil }
        if let cached = rootCache[bundleID] { return cached ?? nil }
        let root = AudioProcessGrouping.rootBundleID(for: bundleID, appKinds: appKinds)
        rootCache[bundleID] = .some(root)
        return root
    }

    /// App 圖示。行程還在就用它的（最快也最準）；已退出的 App
    /// （設定還留著、清單仍要顯示它）退回去查安裝位置。
    ///
    /// 快取而且**回傳同一個 NSImage 實例**：這在每列每次描繪都被呼叫
    /// （拖滑桿＝每秒數十次 × 列數），每次都新建 NSImage 除了慢，
    /// SwiftUI 還會把「新實例」當「圖變了」。圖示在 App 生命週期內
    /// 實務上不變，不設失效。
    func icon(bundleID: String) -> NSImage? {
        if let cached = iconCache.object(forKey: bundleID as NSString) { return cached }
        let icon: NSImage?
        if let pid = entry(bundleID: bundleID)?.pid,
           let running = NSRunningApplication(processIdentifier: pid)?.icon {
            icon = running
        } else if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            icon = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            icon = nil
        }
        if let icon { iconCache.setObject(icon, forKey: bundleID as NSString) }
        return icon
    }
    @ObservationIgnored private let iconCache = NSCache<NSString, NSImage>()

    /// 顯示名稱。行程在就用行程的；不在就查安裝位置；都查不到就退回
    /// bundle id 的最後一段（總比一串反轉網域好認）。
    func displayName(bundleID: String) -> String {
        if let entry = entry(bundleID: bundleID) { return entry.name }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
    }

    func refresh() {
        guard !isFake else { return }
        startListeningIfNeeded()
        cachedOwnProcessObjectID = nil // coreaudiod 重啟後 object 會換，見宣告處
        rootCache = [:] // appKinds 要重建，歸組結果跟著失效
        // App root 來自執行中的 App 清單，不是音訊行程清單——
        // 主 App 可能根本沒有音訊行程（聲音全在 helper 裡）
        appKinds = NSWorkspace.shared.runningApplications.reduce(into: [:]) { kinds, app in
            guard let bundleID = app.bundleIdentifier,
                  let kind = AudioProcessGrouping.Kind(policy: app.activationPolicy)
            else { return }
            kinds[bundleID] = kind
        }
        var listAddress = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size
        ) == noErr, size > 0 else {
            processes = []
            return
        }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &objects
        ) == noErr else { return }

        processes = objects.compactMap { object in
            guard let pid = Self.pidProperty(object) else { return nil }
            let bundleID = CoreAudioProperty.getString(
                object, CoreAudioProperty.address(kAudioProcessPropertyBundleID)
            )
            // Entry.kind 這裡不填（留預設）：正式路徑的歸組與可列性全走
            // appKinds，per-entry 的 kind 只是 DEBUG injectFake 的注入通道
            // ——為它每個行程多查一次 NSRunningApplication 是純浪費
            return Entry(
                objectID: object,
                pid: pid,
                bundleID: (bundleID?.isEmpty == true) ? nil : bundleID,
                name: Self.displayName(pid: pid, bundleID: bundleID),
                isAudible: Self.boolProperty(object, kAudioProcessPropertyIsRunningOutput)
            )
        }
    }

    /// helper 常在音訊開始的那一刻才生出來——tap 描述要跟著補上它，
    /// 不能等使用者下次打開選單才 refresh。
    private func startListeningIfNeeded() {
        guard !listeningForChanges else { return }
        listeningForChanges = true
        var address = CoreAudioProperty.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, .main
        ) { _, _ in
            MainActor.assumeIsolated { [weak self] in
                guard let self else { return }
                self.refresh()
                self.onProcessesChanged?()
            }
        }
    }

    #if DEBUG
    func injectFake(_ entries: [Entry]) {
        isFake = true
        rootCache = [:]
        processes = entries
        // fake 沒有 NSWorkspace 可查：App root 直接取自 entries 自己的身分
        appKinds = entries.reduce(into: [:]) { kinds, entry in
            guard let bundleID = entry.bundleID, entry.kind != .other else { return }
            kinds[bundleID] = entry.kind
        }
        onProcessesChanged?()
    }
    #endif

    // MARK: - property 讀取

    private func translate(pid: pid_t) -> AudioObjectID? {
        var address = CoreAudioProperty.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var input = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &input) { pidPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<pid_t>.size), pidPointer, &size, &object
            )
        }
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private nonisolated static func pidProperty(_ object: AudioObjectID) -> pid_t? {
        CoreAudioProperty.get(object, CoreAudioProperty.address(kAudioProcessPropertyPID), as: pid_t.self)
    }

    private nonisolated static func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        CoreAudioProperty.get(object, CoreAudioProperty.address(selector), as: UInt32.self).map { $0 != 0 } ?? false
    }

    private nonisolated static func displayName(pid: pid_t, bundleID: String?) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName {
            return name
        }
        if let bundleID, let tail = bundleID.split(separator: ".").last {
            return String(tail)
        }
        return "pid \(pid)"
    }
}

extension AudioProcessGrouping.Kind {
    /// `NSRunningApplication.activationPolicy` → 歸組身分的唯一映射點
    /// （歸組規則本身在 ChorusCore，但它的輸入編碼是 AppKit 的事）。
    /// `prohibited` 或查不到 → nil，由呼叫端決定略過還是當 `.other`。
    init?(policy: NSApplication.ActivationPolicy?) {
        switch policy {
        case .regular: self = .regularApp
        case .accessory: self = .accessoryApp
        default: return nil
        }
    }
}
