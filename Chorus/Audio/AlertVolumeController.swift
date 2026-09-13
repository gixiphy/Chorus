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
/// **不在主執行緒上跑 AppleScript**（Batch F）：`NSAppleScript` 每次都要編譯、
/// 載入 StandardAdditions，實測 200 多毫秒，而舊版在啟動、每次打開選單、
/// 拖滑桿收尾時都在主執行緒上同步執行——啟動卡頓的大宗就是它。現在走
/// `/usr/bin/osascript`，在專用序列 queue 上跑、有期限；只有自動化「讀現值再
/// 相對調整」與場景擷取這種要當下值的呼叫還會同步等一次。
///
/// 為什麼值得做：「會議模式」場景要的是**把提示音關掉而不動音樂**。
/// 用輸出音量做不到這件事——那會把兩者一起關掉。
@MainActor
@Observable
final class AlertVolumeController {
    private(set) var volume: Double = 1
    /// 讀到過系統現值沒有。還沒讀到之前顯示的是預設的 1（提示音預設全音量）。
    private(set) var isKnown = false

    /// 即時生效的寫入通道（0–100）。可注入：單元測試不動真機音量。任何執行緒都可呼叫。
    @ObservationIgnored let applyLive: @Sendable (Int) -> Void
    /// 即時現值的讀取通道（0–100；讀不到回 nil）。任何執行緒都可呼叫。
    @ObservationIgnored let readLive: @Sendable () -> Int?
    /// 上次送出的整數值。滑桿拖動每秒幾十個 tick，同一個百分比重跑一次
    /// AppleScript 是純浪費。
    @ObservationIgnored private var lastApplied: Int?
    @ObservationIgnored private let worker = DispatchQueue(label: "com.hermes.Chorus.alert-volume", qos: .userInitiated)
    /// 每次使用者設定 +1。背景讀回來時世代已經變了，就不拿舊讀值蓋掉使用者剛設的值。
    @ObservationIgnored private var writeGeneration = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var applyTask: Task<Void, Never>?
    @ObservationIgnored private var pendingPercent: Int?

    init(
        applyLive: @escaping @Sendable (Int) -> Void = AlertVolumeController.osascriptSet,
        readLive: @escaping @Sendable () -> Int? = AlertVolumeController.osascriptGet,
        refreshOnInit: Bool = true
    ) {
        self.applyLive = applyLive
        self.readLive = readLive
        if refreshOnInit {
            refreshInBackground()
        }
    }

    /// 同步讀現值。**會等一次 AppleScript**——只給需要當下值的呼叫（自動化的
    /// 相對調整、場景擷取）；畫面用 `refreshInBackground`。
    func refresh() {
        applyTask?.cancel()
        applyTask = nil
        pendingPercent = nil
        let live = OperationMetrics.shared.measure("audio.alertVolume.read") { readLive() }
        adopt(live)
    }

    /// 背景讀現值：啟動與打開選單用，主執行緒不等。同時只有一輪。
    @discardableResult
    func refreshInBackground() -> Task<Void, Never> {
        if let refreshTask { return refreshTask }
        let read = readLive
        let worker = worker
        let generation = writeGeneration
        let task = Task { [weak self] in
            let live = await withCheckedContinuation { continuation in
                worker.async {
                    continuation.resume(returning: OperationMetrics.shared.measure("audio.alertVolume.read") { read() })
                }
            }
            guard let self else { return }
            refreshTask = nil
            // 讀的期間使用者動過滑桿：以使用者的值為準
            guard generation == writeGeneration else { return }
            adopt(live)
        }
        refreshTask = task
        return task
    }

    func setVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        isKnown = true
        writeGeneration += 1
        let percent = Int((clamped * 100).rounded())
        guard percent != lastApplied else { return }
        lastApplied = percent
        apply(percent)
    }

    /// 拖桿用：顯示值立即更新，套用合併到尾端（100 ms 內只跑最後一筆）。
    func setVolumeCoalesced(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        volume = clamped
        isKnown = true
        writeGeneration += 1
        let percent = Int((clamped * 100).rounded())
        guard percent != lastApplied else { return }
        pendingPercent = percent
        guard applyTask == nil else { return } // 尾端已排程，更新 pending 即可
        applyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled, let self else { return }
            applyTask = nil
            if let pending = pendingPercent, pending != lastApplied {
                lastApplied = pending
                apply(pending)
            }
            pendingPercent = nil
        }
    }

    /// 等已經送出的寫入跑完（測試與需要確定落地的呼叫端用）。
    func waitForPendingWrites() async {
        await withCheckedContinuation { continuation in
            worker.async { continuation.resume() }
        }
    }

    private func adopt(_ live: Int?) {
        volume = live.map { Double($0) / 100 } ?? 1
        isKnown = live != nil
        // 去重基準對齊剛讀到的現值。少了這行，外部（系統設定）改過之後
        // 把滑桿拉回「上次我們套用的值」會被 lastApplied 吞掉——
        // UI 顯示新值、系統停在舊值，正是 D22 那種「調了沒效果」
        lastApplied = live
    }

    private func apply(_ percent: Int) {
        let applyLive = applyLive
        worker.async {
            OperationMetrics.shared.measure("audio.alertVolume.write") { applyLive(percent) }
        }
    }

    // MARK: - AppleScript 通道（osascript，任何執行緒可用）

    nonisolated static func osascriptSet(_ percent: Int) {
        _ = runOSAScript("set volume alert volume \(percent)")
    }

    nonisolated static func osascriptGet() -> Int? {
        runOSAScript("alert volume of (get volume settings)").flatMap { Int($0) }
    }

    /// 最多等 3 秒；逾時就結束行程、回 nil（讀不到就維持舊值，不卡住 worker）。
    nonisolated private static func runOSAScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        guard finished.wait(timeout: .now() + 3) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
