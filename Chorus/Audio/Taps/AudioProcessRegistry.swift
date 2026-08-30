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
    var ownProcessObjectID: AudioObjectID? {
        translate(pid: ProcessInfo.processInfo.processIdentifier)
    }

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
            .sorted {
                displayName(bundleID: $0).localizedStandardCompare(displayName(bundleID: $1))
                    == .orderedAscending
            }
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

    private func rootBundleID(of entry: Entry) -> String? {
        guard let bundleID = entry.bundleID else { return nil }
        return AudioProcessGrouping.rootBundleID(
            for: bundleID, appBundleIDs: Set(appKinds.keys)
        )
    }

    /// App 圖示。行程還在就用它的（最快也最準）；已退出的 App
    /// （設定還留著、清單仍要顯示它）退回去查安裝位置。
    func icon(bundleID: String) -> NSImage? {
        if let pid = entry(bundleID: bundleID)?.pid,
           let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            return icon
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

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
        // App root 來自執行中的 App 清單，不是音訊行程清單——
        // 主 App 可能根本沒有音訊行程（聲音全在 helper 裡）
        appKinds = NSWorkspace.shared.runningApplications.reduce(into: [:]) { kinds, app in
            guard let bundleID = app.bundleIdentifier else { return }
            switch app.activationPolicy {
            case .regular: kinds[bundleID] = .regularApp
            case .accessory: kinds[bundleID] = .accessoryApp
            default: break
            }
        }
        var listAddress = Self.address(kAudioHardwarePropertyProcessObjectList)
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
            let bundleID = CoreAudioTapBackend.stringProperty(object, kAudioProcessPropertyBundleID)
            let kind: AudioProcessGrouping.Kind =
                switch NSRunningApplication(processIdentifier: pid)?.activationPolicy {
                case .regular: .regularApp
                case .accessory: .accessoryApp
                default: .other // helper、daemon、查不到的行程
                }
            return Entry(
                objectID: object,
                pid: pid,
                bundleID: (bundleID?.isEmpty == true) ? nil : bundleID,
                name: Self.displayName(pid: pid, bundleID: bundleID),
                isAudible: Self.boolProperty(object, kAudioProcessPropertyIsRunningOutput),
                kind: kind
            )
        }
    }

    /// helper 常在音訊開始的那一刻才生出來——tap 描述要跟著補上它，
    /// 不能等使用者下次打開選單才 refresh。
    private func startListeningIfNeeded() {
        guard !listeningForChanges else { return }
        listeningForChanges = true
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
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
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
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

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private nonisolated static func pidProperty(_ object: AudioObjectID) -> pid_t? {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private nonisolated static func boolProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
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
