import ChorusCore
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
    /// 輸出裝置中途重新配置（藍牙耳機切降噪／通透會改取樣率）時觸發。
    /// aggregate 的格式綁在建立時——擁有者收到後應**收舊建新**，
    /// 否則輕則雜音、重則卡在無聲（AirPods 實測，2026-08-30）。
    var onDeviceReconfigured: (@MainActor () -> Void)? { get set }
    func setGain(_ gain: Float)
    func setMuted(_ muted: Bool)
    /// 裝置級左右平衡（−1…+1，0＝置中）。只衰減不增益（BalanceLaw）。
    /// 與裝置 EQ 同一個責任層——per-app session 只在它的輸出裝置正是
    /// 裝置級處理目標時才套。
    func setBalance(_ balance: Float)
    /// 裝置級等化（B6-5）。`nil` 或未生效的設定＝拆掉 EQ，樣本原樣通過。
    func setEQ(_ settings: EQSettings?)
    /// App 層等化（B6-8）——與裝置層是不同責任的兩次，App 層先過。
    func setAppEQ(_ settings: EQSettings?)
    func stop()
}

/// tap 操作的接縫。FineTune 以 `ProcessTapControlling` 協定達成同一目的
/// （行為參考；實作全部自寫）——真實 backend 碰 CoreAudio，
/// FakeTapBackend 讓 E2E 與單元測試不需要權限與真硬體。
@MainActor
protocol TapBackend: AnyObject {
    /// 目前預設輸出裝置的 UID（aggregate 的 clock 來源與寫回目標）。
    func defaultOutputDeviceUID() -> String?
    /// 目前存在的輸出裝置 UID。路由（B6-3）要靠它分辨「使用者指定的裝置
    /// 還在不在」——建 aggregate 失敗的錯誤碼分不出「裝置被拔掉」與
    /// 「這台機器有別的問題」，前者該退回預設並說明，後者不該。
    func outputDeviceUIDs() -> [String]
    /// 權限探測：全域 unmuted tap、只讀不寫。`excluding` 至少要含自己的
    /// process object（回音紀律，DESIGN §2.3 規則 1）。
    func startProbeSession(
        outputDeviceUID: String,
        excludingProcessObjects: [AudioObjectID]
    ) throws -> any TapSession
    /// 正式 per-app：以 bundle id 定位（macOS 26 的 `bundleIDs`＋
    /// `processRestoreEnabled`，App 重啟由系統重綁）、mutedWhenTapped、
    /// 處理後寫回輸出裝置。
    ///
    /// `memberBundleIDs` 是描述要涵蓋的整組 bundle（root＋helper）——
    /// 瀏覽器類 App 的聲音從 helper 行程出來，只描述主 bundle 會抓不到。
    ///
    /// `initialGain` 讓 session 從使用者設定的值起步。少了它，一個設成
    /// 20% 的 App 每次重啟都會先響一段全音量再滑下去。
    func startPlaythroughSession(
        bundleID: String,
        memberBundleIDs: [String],
        outputDeviceUID: String,
        initialGain: Float
    ) throws -> any TapSession
    /// 裝置級軟體音量（B6-4）：排除式全域 tap，處理後寫回該裝置。
    /// `excludingProcessObjects` 必須含 Chorus 自己**與所有已被 per-app
    /// tap 捕獲的行程**——每一路音訊只能被處理一次（DESIGN §2.2）。
    func startGlobalVolumeSession(
        outputDeviceUID: String,
        excludingProcessObjects: [AudioObjectID],
        initialGain: Float
    ) throws -> any TapSession
    /// 預設輸出裝置變更（session 要搬家）。
    func setDefaultOutputChangedHandler(_ handler: @escaping @MainActor () -> Void)
}

extension TapBackend {
    /// 回音紀律的共同防呆：絕不 tap Chorus 自己（含歸組成員）。
    /// 放在協定層——policy 只寫一份，fake 與真實 backend 必然一致，
    /// 測試驗到的就是正式路徑的那條規則。
    func rejectSelfTap(bundleID: String, memberBundleIDs: [String]) throws {
        if let own = Bundle.main.bundleIdentifier,
           bundleID == own || memberBundleIDs.contains(own) {
            throw TapBackendError.refusedSelfTap
        }
    }
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
