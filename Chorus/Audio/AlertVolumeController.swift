import Foundation
import Observation

/// 提示音（alert／beep）音量的獨立控制（B6-7）。
///
/// macOS 的提示音音量與輸出音量是**兩個不同的東西**——「聲音」設定裡
/// 那條獨立的滑桿。
///
/// **通道（2026-08-30 實測改判）**：`NSGlobalDomain` 的
/// `com.apple.sound.beep.volume` 在 macOS 26 上**不驅動**即時值——寫進去
/// 系統值反而變無效，而且那個鍵是系統自己回填的**非線性**快取
/// （alert volume 30 ↔ 鍵值 0.497），驗收 D22 就是這樣「調了沒效果」。
/// 活的通道是 AppleScript 的 `set volume alert volume`（0–100，
/// StandardAdditions 對自己執行，不觸發 Automation 權限）。
///
/// 為什麼值得做：「會議模式」場景要的是**把提示音關掉而不動音樂**。
/// 用輸出音量做不到這件事——那會把兩者一起關掉。
@MainActor
@Observable
final class AlertVolumeController {
    private(set) var volume: Double = 0

    /// 即時生效的寫入通道（0–100）。可注入：單元測試不動真機音量。
    @ObservationIgnored let applyLive: (Int) -> Void
    /// 即時現值的讀取通道（0–100；讀不到回 nil）。
    @ObservationIgnored let readLive: () -> Int?
    /// 上次送出的整數值。滑桿拖動每秒幾十個 tick，同一個百分比重跑一次
    /// AppleScript（每次都重新編譯）是純浪費。
    @ObservationIgnored private var lastApplied: Int?

    init(
        applyLive: @escaping (Int) -> Void = AlertVolumeController.appleScriptSet,
        readLive: @escaping () -> Int? = AlertVolumeController.appleScriptGet
    ) {
        self.applyLive = applyLive
        self.readLive = readLive
        refresh()
    }

    func refresh() {
        applyTask?.cancel()
        applyTask = nil
        pendingPercent = nil
        let live = readLive()
        volume = live.map { Double($0) / 100 } ?? 1
        // 去重基準對齊剛讀到的現值。少了這行，外部（系統設定）改過之後
        // 把滑桿拉回「上次我們套用的值」會被 lastApplied 吞掉——
        // UI 顯示新值、系統停在舊值，正是 D22 那種「調了沒效果」
        lastApplied = live
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        let percent = Int((clamped * 100).rounded())
        guard percent != lastApplied else { return }
        lastApplied = percent
        applyLive(percent)
    }

    /// 拖桿用：顯示值立即更新，AppleScript 套用合併到尾端（100 ms 內
    /// 只跑最後一筆）。`applyLive` 是主執行緒上的同步編譯＋執行，
    /// 拖動時每一格都跑會讓整個選單卡住。
    func setVolumeCoalesced(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        let percent = Int((clamped * 100).rounded())
        guard percent != lastApplied else { return }
        pendingPercent = percent
        guard applyTask == nil else { return } // 尾端已排程，更新 pending 即可
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            self.applyTask = nil
            if let pending = self.pendingPercent, pending != self.lastApplied {
                self.lastApplied = pending
                self.applyLive(pending)
            }
            self.pendingPercent = nil
        }
    }
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPercent: Int?

    // MARK: - AppleScript 通道

    nonisolated static func appleScriptSet(_ percent: Int) {
        NSAppleScript(source: "set volume alert volume \(percent)")?
            .executeAndReturnError(nil)
    }

    nonisolated static func appleScriptGet() -> Int? {
        guard let descriptor = NSAppleScript(source: "alert volume of (get volume settings)")?
            .executeAndReturnError(nil)
        else { return nil }
        let value = Int(descriptor.int32Value)
        // 描述元不是數字時 int32Value 回 0——0 又是合法音量，
        // 用型別碼分辨「真的 0」與「解析失敗」
        return descriptor.descriptorType == typeSInt32 ? value : nil
    }
}
