import CoreAudio
import Foundation

/// AudioObjectGet/SetPropertyData 的型別化薄封裝。
/// 只能在 AudioWorker 的 serial queue 上呼叫（CoreAudio 呼叫可能阻塞）。
enum CoreAudioProperty {
    /// kAudioHardwareServiceDeviceProperty_VirtualMainVolume（'vmvc'）。
    /// 常數宣告在已棄用的 AudioHardwareService.h，但 selector 本身由 HAL 直接支援，
    /// 會自動處理「main element 無音量但 channel 有」的情況。
    static let virtualMainVolume = AudioObjectPropertySelector(0x766D_7663)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        return AudioObjectHasProperty(objectID, &address)
    }

    static func isSettable(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    /// 讀取固定大小的純量值（UInt32、Float32、AudioObjectID…）。
    static func get<T>(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, as type: T.Type) -> T? {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer) == noErr else { return nil }
        return pointer.pointee
    }

    /// 讀取元素陣列（如裝置清單）。
    static func getArray<T>(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, of _: T.Type) -> [T]? {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<T>.stride
        guard count > 0 else { return [] }
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        defer { pointer.deallocate() }
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer) == noErr else { return nil }
        let readCount = Int(size) / MemoryLayout<T>.stride
        return Array(UnsafeBufferPointer(start: pointer, count: readCount))
    }

    static func getString(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress) -> String? {
        var address = address
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    @discardableResult
    static func set<T>(_ objectID: AudioObjectID, _ address: AudioObjectPropertyAddress, to value: T) -> Bool {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<T>.size)
        return AudioObjectSetPropertyData(objectID, &address, 0, nil, size, &value) == noErr
    }

    /// 該物件在指定 scope 是否有 stream（用來判斷輸出/輸入裝置）。
    static func hasStreams(_ objectID: AudioObjectID, scope: AudioObjectPropertyScope) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size) == noErr else { return false }
        return size > 0
    }
}
