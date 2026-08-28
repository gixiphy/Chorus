import CoreAudio
import Foundation

/// tap session 的種類。**混淆兩者會出事**：
/// - 探測（權限確認）必須 `captureOnly`＋unmuted——來源照常播放，我們只讀不寫。
///   若寫回輸出就是同一份音訊播兩次（回音）。
/// - 正式 per-app 必須 `playthrough`＋mutedWhenTapped——來源在系統端被靜音，
///   由我們處理後寫回輸出。若不寫回就是整個 App 無聲。
enum TapSessionKind: Sendable, Equatable {
    case captureOnly
    case playthrough
}

/// IOProc 端以 atomic 累計、主執行緒讀取的統計。
/// `nonZeroCallbacks` 是權限判讀的原料（TapHealthMonitor）。
struct TapSessionStats: Sendable, Equatable {
    var callbacks = 0
    var nonZeroCallbacks = 0

    static func - (lhs: TapSessionStats, rhs: TapSessionStats) -> TapSessionStats {
        TapSessionStats(
            callbacks: lhs.callbacks - rhs.callbacks,
            nonZeroCallbacks: lhs.nonZeroCallbacks - rhs.nonZeroCallbacks
        )
    }
}

/// 一條進行中的 tap。stop() 冪等；擁有者（TapEngine）負責在收掉時呼叫。
@MainActor
protocol TapSession: AnyObject {
    var kind: TapSessionKind { get }
    var stats: TapSessionStats { get }
    func setGain(_ gain: Float)
    func setMuted(_ muted: Bool)
    func stop()
}

/// tap 操作的接縫。FineTune 以 `ProcessTapControlling` 協定達成同一目的
/// （行為參考；實作全部自寫）——真實 backend 碰 CoreAudio，
/// FakeTapBackend 讓 E2E 與單元測試不需要權限與真硬體。
@MainActor
protocol TapBackend: AnyObject {
    /// 目前預設輸出裝置的 UID（aggregate 的 clock 來源與寫回目標）。
    func defaultOutputDeviceUID() -> String?
    /// 權限探測：全域 unmuted tap、只讀不寫。`excluding` 至少要含自己的
    /// process object（回音紀律，DESIGN §2.3 規則 1）。
    func startProbeSession(
        outputDeviceUID: String,
        excludingProcessObjects: [AudioObjectID]
    ) throws -> any TapSession
    /// 正式 per-app：以 bundle id 定位（macOS 26 的 `bundleIDs`＋
    /// `processRestoreEnabled`，App 重啟由系統重綁）、mutedWhenTapped、
    /// 處理後寫回輸出裝置。
    func startPlaythroughSession(
        bundleID: String,
        outputDeviceUID: String
    ) throws -> any TapSession
    /// 預設輸出裝置變更（session 要搬家）。
    func setDefaultOutputChangedHandler(_ handler: @escaping @MainActor () -> Void)
}

enum TapBackendError: Error, Equatable {
    case noOutputDevice
    case createTapFailed(OSStatus)
    case tapUIDUnavailable
    case createAggregateFailed(OSStatus)
    case createIOProcFailed(OSStatus)
    case startFailed(OSStatus)
    /// 防呆：嘗試 tap Chorus 自己（回音）。
    case refusedSelfTap
}
