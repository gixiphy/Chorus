import CoreGraphics
import Foundation

/// HDR 狀態（私有 API 動態解析）。符號缺失時整機仍可啟動；寫入未驗證前僅供狀態顯示。
@MainActor
final class HDRClient {
    enum Status: String, Sendable, Equatable {
        case unsupported
        case unknown
        case off
        case on
    }

    enum SetError: Error, Equatable {
        case unsupported
        case poweredOff
        case writeFailed
        case readbackMismatch
    }

    private typealias InfoDictionaryFn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?
    private typealias SetHDRFn = @convention(c) (CGDirectDisplayID, Bool) -> Int32

    private let infoFn: InfoDictionaryFn?
    private let setHDRFn: SetHDRFn?
    /// 寫入 API 是否可用。設計要求還原可靠後才開控制；目前即使符號在也預設只讀。
    private(set) var writesEnabled = false

    var canReadStatus: Bool { infoFn != nil }
    var isWriteAvailable: Bool { setHDRFn != nil && writesEnabled }

    init() {
        let path = "/System/Library/PrivateFrameworks/CoreDisplay.framework/CoreDisplay"
        guard let handle = dlopen(path, RTLD_LAZY) else {
            infoFn = nil
            setHDRFn = nil
            return
        }
        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }
        infoFn = symbol("CoreDisplay_DisplayCreateInfoDictionary", as: InfoDictionaryFn.self)
            ?? symbol("CoreDisplayCreateDisplayInfoDictionary", as: InfoDictionaryFn.self)
        // 常見私有符號名；缺失＝不支援寫入
        setHDRFn = symbol("CoreDisplay_Display_SetForceHDRMode", as: SetHDRFn.self)
            ?? symbol("CoreDisplaySetForceHDRMode", as: SetHDRFn.self)
    }

    /// 診斷／開發用：明確開啟寫入（預設關閉，符合「還原未驗證不開控制」）。
    func setWritesEnabled(_ enabled: Bool) {
        writesEnabled = enabled && setHDRFn != nil
    }

    func status(for displayID: CGDirectDisplayID) -> Status {
        guard let infoFn else { return .unsupported }
        guard let unmanaged = infoFn(displayID) else { return .unknown }
        let dict = unmanaged.takeRetainedValue() as NSDictionary
        // 嘗試多個已知鍵；都沒有＝unknown（能力存在但無法判讀）
        let keys = [
            "HDR", "hdr", "DisplayHDREnabled", "HDREnabled",
            "AmbientDisplayHDRMode", "HDRMode"
        ]
        for key in keys {
            if let number = dict[key] as? NSNumber {
                return number.boolValue ? .on : .off
            }
            if let string = dict[key] as? String {
                let lower = string.lowercased()
                if ["1", "true", "yes", "on"].contains(lower) { return .on }
                if ["0", "false", "no", "off"].contains(lower) { return .off }
            }
        }
        if let capable = dict["DisplayHDRCapable"] as? NSNumber ?? dict["HDRCapable"] as? NSNumber {
            return capable.boolValue ? .off : .unsupported
        }
        return .unknown
    }

    @discardableResult
    func setHDR(_ enabled: Bool, for displayID: CGDirectDisplayID) -> Result<Status, SetError> {
        guard isWriteAvailable, let setHDRFn else { return .failure(.unsupported) }
        let status = OperationMetrics.shared.measure("display.hdr") {
            setHDRFn(displayID, enabled)
        }
        guard status == 0 else { return .failure(.writeFailed) }
        let actual = self.status(for: displayID)
        switch actual {
        case .on where enabled, .off where !enabled:
            return .success(actual)
        case .unsupported, .unknown:
            return .success(actual)
        default:
            return .failure(.readbackMismatch)
        }
    }
}
