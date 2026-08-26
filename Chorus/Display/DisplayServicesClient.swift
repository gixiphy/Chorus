import CoreGraphics
import Foundation

/// private DisplayServices.framework 的 dlopen/dlsym 包裝。
/// 控制內建面板與 Apple 認可顯示器（Studio Display、LG UltraFine 等）。
/// 任一符號缺失時對應功能回報不可用，呼叫端降級到 gamma 調光。
final class DisplayServicesClient: @unchecked Sendable {
    private typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias BrightnessChangedFn = @convention(c) (CGDirectDisplayID, Double) -> Void

    private let getFn: GetBrightnessFn?
    private let setFn: SetBrightnessFn?
    private let canChangeFn: CanChangeFn?
    private let changedFn: BrightnessChangedFn?

    init() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        ) else {
            getFn = nil
            setFn = nil
            canChangeFn = nil
            changedFn = nil
            return
        }

        func symbol<T>(_ name: String, as _: T.Type) -> T? {
            guard let sym = dlsym(handle, name) else { return nil }
            return unsafeBitCast(sym, to: T.self)
        }

        getFn = symbol("DisplayServicesGetBrightness", as: GetBrightnessFn.self)
        setFn = symbol("DisplayServicesSetBrightness", as: SetBrightnessFn.self)
        canChangeFn = symbol("DisplayServicesCanChangeBrightness", as: CanChangeFn.self)
        changedFn = symbol("DisplayServicesBrightnessChanged", as: BrightnessChangedFn.self)
    }

    var isAvailable: Bool { getFn != nil && setFn != nil }

    func canChangeBrightness(_ displayID: CGDirectDisplayID) -> Bool {
        guard isAvailable, let canChangeFn else { return false }
        return canChangeFn(displayID)
    }

    func brightness(for displayID: CGDirectDisplayID) -> Double? {
        guard let getFn else { return nil }
        var value: Float = 0
        guard getFn(displayID, &value) == 0 else { return nil }
        return Double(value)
    }

    @discardableResult
    func setBrightness(_ value: Double, for displayID: CGDirectDisplayID) -> Bool {
        guard let setFn else { return false }
        let clamped = Float(min(max(value, 0), 1))
        guard setFn(displayID, clamped) == 0 else { return false }
        // 通知系統，讓系統亮度 OSD／設定同步顯示新值
        changedFn?(displayID, Double(clamped))
        return true
    }
}
