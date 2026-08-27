import Foundation

/// 環境光感器（ALS）讀取：IOKit 私有 IOHIDEventSystemClient SPI 的 dlopen/dlsym 包裝。
/// 仿 DisplayServicesClient 先例 —— 任一符號缺失或找不到感器服務時 isAvailable = false，
/// 呼叫端降級為「無感器、跟隨 peer 基準」，不會 dyld 崩潰。
///
/// 桌上型 Mac（mini / Studio / Pro）沒有 ALS，屬正常情況。
/// 採輪詢（Copy 事件）而非註冊 callback，避開 monitor-type client 可能牽動的 TCC。
final class AmbientLightSensorClient: @unchecked Sendable {
    private typealias ClientCreateFn = @convention(c) (UnsafeRawPointer?) -> UnsafeMutableRawPointer?
    private typealias SetMatchingFn = @convention(c) (UnsafeMutableRawPointer, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer?
    private typealias CopyEventFn = @convention(c) (UnsafeMutableRawPointer, Int64, Int32, Int64) -> UnsafeMutableRawPointer?
    private typealias GetFloatFn = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Double

    /// kIOHIDEventTypeAmbientLightSensor
    private static let eventType: Int64 = 12
    /// kIOHIDEventFieldAmbientLightSensorLevel = type << 16
    private static let luxField: UInt32 = 12 << 16

    private let copyEventFn: CopyEventFn?
    private let getFloatFn: GetFloatFn?
    /// 保留的 IOHIDEventSystemClient 與感器 service（CFRetain 過，deinit 釋放）。
    private let client: UnsafeMutableRawPointer?
    private let sensorService: UnsafeMutableRawPointer?

    #if DEBUG
    /// `--fake-als`：無實體感器的機器（桌機、同機多實例 E2E）模擬一顆感器，
    /// 讀值由 TestHooks 的 injectLux 控制。
    private let fake: Bool
    private let fakeLock = NSLock()
    private var fakeLuxValue: Double = 500
    #endif

    init(fakeALS: Bool = false, disabled: Bool = false) {
        #if DEBUG
        fake = fakeALS && !disabled
        if fakeALS || disabled {
            copyEventFn = nil
            getFloatFn = nil
            client = nil
            sensorService = nil
            return
        }
        #endif

        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY) else {
            copyEventFn = nil
            getFloatFn = nil
            client = nil
            sensorService = nil
            return
        }

        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }

        let createFn = symbol("IOHIDEventSystemClientCreate", as: ClientCreateFn.self)
        let setMatchingFn = symbol("IOHIDEventSystemClientSetMatching", as: SetMatchingFn.self)
        let copyServicesFn = symbol("IOHIDEventSystemClientCopyServices", as: CopyServicesFn.self)
        copyEventFn = symbol("IOHIDServiceClientCopyEvent", as: CopyEventFn.self)
        getFloatFn = symbol("IOHIDEventGetFloatValue", as: GetFloatFn.self)

        guard let createFn, let setMatchingFn, let copyServicesFn,
              copyEventFn != nil, getFloatFn != nil,
              let created = createFn(nil)
        else {
            client = nil
            sensorService = nil
            return
        }

        // AppleVendor page (0xff00) / AmbientLightSensor usage (4)
        let matching = [
            "PrimaryUsagePage": 0xff00,
            "PrimaryUsage": 4,
        ] as CFDictionary
        setMatchingFn(created, matching)

        guard let servicesPtr = copyServicesFn(created) else {
            Self.release(created)
            client = nil
            sensorService = nil
            return
        }
        let services = unsafeBitCast(servicesPtr, to: CFArray.self)
        var found: UnsafeMutableRawPointer?
        for index in 0..<CFArrayGetCount(services) {
            guard let raw = CFArrayGetValueAtIndex(services, index) else { continue }
            let service = UnsafeMutableRawPointer(mutating: raw)
            found = service
            break
        }
        if let found {
            _ = Unmanaged<AnyObject>.fromOpaque(found).retain()
        }
        Self.release(servicesPtr)

        client = created
        sensorService = found
    }

    deinit {
        if let sensorService { Self.release(sensorService) }
        if let client { Self.release(client) }
    }

    var isAvailable: Bool {
        #if DEBUG
        if fake { return true }
        #endif
        return sensorService != nil
    }

    /// 目前環境光（lux）。感器不可用或事件讀取失敗時 nil。
    func readLux() -> Double? {
        #if DEBUG
        if fake {
            fakeLock.lock()
            defer { fakeLock.unlock() }
            return fakeLuxValue
        }
        #endif
        guard let sensorService, let copyEventFn, let getFloatFn else { return nil }
        guard let event = copyEventFn(sensorService, Self.eventType, 0, 0) else { return nil }
        defer { Self.release(event) }
        let lux = getFloatFn(event, Self.luxField)
        guard lux.isFinite, lux >= 0 else { return nil }
        return lux
    }

    #if DEBUG
    /// TestHooks injectLux 用。
    func setFakeLux(_ value: Double) {
        fakeLock.lock()
        fakeLuxValue = max(value, 0)
        fakeLock.unlock()
    }
    #endif

    private static func release(_ pointer: UnsafeMutableRawPointer) {
        Unmanaged<AnyObject>.fromOpaque(pointer).release()
    }
}
