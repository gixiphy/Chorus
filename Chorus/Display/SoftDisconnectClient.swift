import CoreGraphics
import Foundation

/// Soft-disconnect：把顯示器移出 display layout，效果等同拔線但不用拔線。
/// 內建面板唯一的「真關閉」路徑（DDC 碰不到內建面板）。
///
/// 走 SkyLight 私有 API。這組函式是公開 `CGBeginDisplayConfiguration` 家族
/// 缺的那個成員——同一套 transaction 慣例（begin → configure → complete/cancel）。
/// 以 B3 spike 在 macOS 26.6.2 / arm64 實測確認：
/// - 五個符號皆可解析
/// - 真實 display ID 回 `kCGErrorSuccess`，假 ID 回 `kCGErrorIllegalArgument`
///   （證明第二參數確實被當 display ID 驗證，不是碰巧回 0）
/// - commit 後該顯示器離開 `CGGetActiveDisplayList`，重新啟用後回來
///
/// **崩潰保險**：一律以 `kCGConfigureForAppOnly` 提交——設定只在本 process
/// 存活期間有效，Chorus 意外結束時 macOS 自動把顯示器接回來。
/// 這與 GammaDimmer 的 atexit 還原是同一條紀律：任何「讓螢幕看不見」的狀態
/// 都不能在 App 死掉後留在系統上。
@MainActor
final class SoftDisconnectClient {
    private typealias BeginFn = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    private typealias ConfigureEnabledFn = @convention(c) (UnsafeMutableRawPointer?, UInt32, Bool) -> Int32
    private typealias CompleteFn = @convention(c) (UnsafeMutableRawPointer?, UInt32) -> Int32
    private typealias CancelFn = @convention(c) (UnsafeMutableRawPointer?) -> Int32

    /// `kCGConfigureForAppOnly`：本 process 結束即自動還原。
    private static let forAppOnly: UInt32 = 0

    private let begin: BeginFn
    private let configureEnabled: ConfigureEnabledFn
    private let complete: CompleteFn
    private let cancel: CancelFn

    /// 私有 API 都在位才算可用；任何一個缺席就整個功能不提供
    /// （macOS 改版拿掉符號時誠實降級到 gamma 黑屏，而不是半殘）。
    private(set) var isAvailable = false

    init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
        guard let handle = dlopen(path, RTLD_LAZY),
              let beginPtr = dlsym(handle, "SLSBeginDisplayConfiguration"),
              let enabledPtr = dlsym(handle, "SLSConfigureDisplayEnabled"),
              let completePtr = dlsym(handle, "SLSCompleteDisplayConfigurationWithOption")
                ?? dlsym(handle, "SLSCompleteDisplayConfiguration"),
              let cancelPtr = dlsym(handle, "SLSCancelDisplayConfiguration")
        else {
            begin = { _ in -1 }
            configureEnabled = { _, _, _ in -1 }
            complete = { _, _ in -1 }
            cancel = { _ in -1 }
            return
        }
        begin = unsafeBitCast(beginPtr, to: BeginFn.self)
        configureEnabled = unsafeBitCast(enabledPtr, to: ConfigureEnabledFn.self)
        complete = unsafeBitCast(completePtr, to: CompleteFn.self)
        cancel = unsafeBitCast(cancelPtr, to: CancelFn.self)
        isAvailable = true
    }

    /// 移出／接回 layout。回傳是否成功。
    ///
    /// 失敗時一律 cancel transaction——半開的 configuration 留在系統上
    /// 會讓後續的顯示器設定（包含 macOS 自己的）行為不可預期。
    @discardableResult
    func setEnabled(_ enabled: Bool, displayID: CGDirectDisplayID) -> Bool {
        guard isAvailable else { return false }
        var config: UnsafeMutableRawPointer?
        guard begin(&config) == 0, config != nil else { return false }
        guard configureEnabled(config, displayID, enabled) == 0 else {
            _ = cancel(config)
            return false
        }
        return complete(config, Self.forAppOnly) == 0
    }
}
