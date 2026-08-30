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
    @ObservationIgnored var applyLive: (Int) -> Void
    /// 即時現值的讀取通道（0–100；讀不到回 nil）。
    @ObservationIgnored var readLive: () -> Int?

    init(
        applyLive: @escaping (Int) -> Void = AlertVolumeController.appleScriptSet,
        readLive: @escaping () -> Int? = AlertVolumeController.appleScriptGet
    ) {
        self.applyLive = applyLive
        self.readLive = readLive
        refresh()
    }

    func refresh() {
        volume = readLive().map { Double($0) / 100 } ?? 1
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        applyLive(Int((clamped * 100).rounded()))
    }

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
