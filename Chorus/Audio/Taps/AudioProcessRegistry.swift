import AppKit
import CoreAudio
import Foundation
import Observation

/// 系統 audio process 物件的清單（`kAudioHardwarePropertyProcessObjectList`）。
/// per-app 音量的「App 清單」與健康判讀的「誰在發聲」都從這裡來。
@MainActor
@Observable
final class AudioProcessRegistry {
    struct Entry: Identifiable, Sendable, Equatable {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String?
        let name: String
        var isAudible: Bool
        var id: AudioObjectID { objectID }
    }

    private(set) var processes: [Entry] = []
    /// TestHooks 注入 fake 清單後鎖住，真實 refresh 不再覆蓋。
    private(set) var isFake = false

    /// Chorus 自己的 process object（回音紀律：探測的排除清單至少要有它）。
    var ownProcessObjectID: AudioObjectID? {
        translate(pid: ProcessInfo.processInfo.processIdentifier)
    }

    /// 有任何**非自己**的來源正在發聲（健康判讀的 audible 訊號）。
    var anyOtherProcessAudible: Bool {
        let ownPid = ProcessInfo.processInfo.processIdentifier
        return processes.contains { $0.isAudible && $0.pid != ownPid }
    }

    /// 選單列 per-app 清單的來源：有 bundle id、不是 Chorus 自己
    /// （回音紀律：我們不 tap 自己），依名稱排序。
    var controllableProcesses: [Entry] {
        let ownBundle = Bundle.main.bundleIdentifier
        return processes
            .filter { $0.bundleID != nil && $0.bundleID != ownBundle }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func entry(bundleID: String) -> Entry? {
        processes.first { $0.bundleID == bundleID }
    }

    /// 這些 bundle 對應的 process object。裝置級全域 tap 要拿它來排除
    /// 已被 per-app tap 捕獲的行程——每一路音訊只處理一次（DESIGN §2.2）。
    /// 一個 bundle 可能有多個行程（helper），所以是多對多。
    func processObjectIDs(bundleIDs: Set<String>) -> [AudioObjectID] {
        processes.filter { $0.bundleID.map(bundleIDs.contains) ?? false }.map(\.objectID)
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
            return Entry(
                objectID: object,
                pid: pid,
                bundleID: (bundleID?.isEmpty == true) ? nil : bundleID,
                name: Self.displayName(pid: pid, bundleID: bundleID),
                isAudible: Self.boolProperty(object, kAudioProcessPropertyIsRunningOutput)
            )
        }
    }

    #if DEBUG
    func injectFake(_ entries: [Entry]) {
        isFake = true
        processes = entries
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
