import AppKit
import ApplicationServices
import ChorusCore
import Observation

/// 緊急復原手勢（M9）：時間窗內連按 8 次 ⌘ → 把所有被 Chorus 關掉的螢幕
/// 全部開回來。學 Lunar 的做法，目的只有一個：**不要讓使用者被鎖在黑屏裡**。
///
/// 紀律：
/// - **只在真的有螢幕被關掉時掛監聽**。沒有黑屏就沒有事件監聽器，
///   不會平白長駐一個鍵盤 hook。
/// - 全域監聽需輔助使用權限。**沒授權也不會失效整個功能**——監聽器照掛
///   （本機焦點在 Chorus 時仍收得到），並誠實把 `isTrusted` 回報給 UI，
///   讓電源鈕旁邊能講清楚「這個手勢現在有沒有用」。
/// - 這是安全網不是唯一出口：`kCGConfigureForAppOnly` 與 gamma 的 atexit
///   還原代表「結束 Chorus」永遠救得回來，手勢失效也不會真的鎖死。
@MainActor
@Observable
final class EmergencyRestoreMonitor {
    /// 監聽器目前掛著（＝有螢幕被關掉）。
    private(set) var isArmed = false
    /// 有輔助使用權限＝全域按鍵收得到，手勢在任何 App 前景時都有效。
    private(set) var isTrusted = false

    @ObservationIgnored private weak var displayManager: DisplayManager?
    @ObservationIgnored private var detector = EmergencyGestureDetector()
    @ObservationIgnored private var globalMonitor: Any?
    @ObservationIgnored private var localMonitor: Any?
    /// 上一次事件時 ⌘ 是否為按下狀態（flagsChanged 沒有 up/down，只能自己比對）。
    @ObservationIgnored private var commandWasDown = false

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    /// 有／沒有被關掉的螢幕時由 DisplayManager 呼叫。
    func updateArming(active: Bool) {
        if active { arm() } else { disarm() }
    }

    private func arm() {
        guard !isArmed else { return }
        isTrusted = AXIsProcessTrusted()
        detector.reset()
        commandWasDown = false
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
        isArmed = true
    }

    private func disarm() {
        guard isArmed else { return }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        detector.reset()
        isArmed = false
    }

    #if DEBUG
    /// E2E 注入：不經 CGEvent、不需輔助使用權限，直接把 N 次「⌘ 按下」
    /// 餵進同一個狀態機——測的是真的那條路徑，不是另寫一份捷徑。
    func debugSimulateCommandPresses(_ count: Int) {
        let now = ProcessInfo.processInfo.systemUptime
        for index in 0..<count {
            guard detector.record(at: now + Double(index) * 0.05) else { continue }
            _ = displayManager?.restoreAllDisplayPower()
        }
    }
    #endif

    private func handle(_ event: NSEvent) {
        let isDown = event.modifierFlags.contains(.command)
        defer { commandWasDown = isDown }
        // 只算「按下」那一刻；放開不算，長按也只算一次
        guard isDown, !commandWasDown else { return }
        guard detector.record(at: ProcessInfo.processInfo.systemUptime) else { return }
        let restored = displayManager?.restoreAllDisplayPower() ?? 0
        guard restored > 0 else { return }
        NSSound.beep()
    }
}
