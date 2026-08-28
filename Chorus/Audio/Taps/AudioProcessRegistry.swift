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
