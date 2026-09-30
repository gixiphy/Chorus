import AppKit
import ChorusCore
import Foundation
import Observation

/// 藍牙耳機電量：查 `system_profiler`、排程輪詢、把結果交給選單列／選單列。
///
/// 查詢在背景跑、不走 AudioWorker 音量佇列——拖曳音量時不能被電量查詢卡住。
@MainActor
@Observable
final class HeadsetBatteryMonitor {
    private(set) var battery: HeadsetBattery?
    private(set) var targetUID: String?

    @ObservationIgnored private weak var audioManager: AudioDeviceManager?
    @ObservationIgnored private weak var settings: SettingsStore?
    @ObservationIgnored private var menuOpen = false
    @ObservationIgnored private var lastSuccess: ContinuousClock.Instant?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var retryTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private let log = ChorusLog(category: "headsetBattery")
    @ObservationIgnored private let clock = ContinuousClock()

    func attach(audioManager: AudioDeviceManager, settings: SettingsStore) {
        self.audioManager = audioManager
        self.settings = settings
        audioManager.headsetBattery = self
        installWakeObserver()
        syncFromAudioManager()
    }

    deinit {
        // deinit 非 isolated；observer 清理由 shutDown／取消 Task 處理。
    }

    func shutDown() {
        pollTask?.cancel()
        pollTask = nil
        retryTasks.forEach { $0.cancel() }
        retryTasks = []
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        battery = nil
        targetUID = nil
        lastSuccess = nil
    }

    /// 音訊 snapshot／轉送目標變了 → 重算目前該追哪台藍牙輸出。
    func syncFromAudioManager() {
        guard let audioManager else { return }
        // 只有預設輸出**就是**虛擬裝置時才看轉送目標——driver 的目標平常一直掛在
        // 螢幕上，預設輸出換成 AirPods 時它不會清掉。
        let current = audioManager.defaultDevice
        let device = current?.uid == VirtualAudioDriverController.deviceUID
            ? audioManager.virtualForwardTarget
            : current
        let uid = (device?.isBluetooth == true) ? device?.uid : nil
        track(uid: uid)
    }

    func menuVisibilityChanged(_ open: Bool) {
        menuOpen = open
        if open {
            let age = lastSuccess.map { clock.now - $0 }
            if HeadsetBatteryPolicy.shouldRefreshOnMenuOpen(age: age) {
                Task { await refreshNow() }
            }
        }
        reevaluatePolling()
    }

    func menuBarSettingChanged() {
        reevaluatePolling()
    }

    // MARK: - Target

    private func track(uid: String?) {
        if uid == targetUID {
            reevaluatePolling()
            return
        }
        let previous = targetUID
        targetUID = uid
        battery = nil
        lastSuccess = nil
        retryTasks.forEach { $0.cancel() }
        retryTasks = []

        if let uid {
            log.notice("耳機電量目標：\(previous ?? "無") → \(uid)")
            scheduleConnectRetries()
        } else if previous != nil {
            log.notice("耳機電量目標：\(previous ?? "無") → 無")
        }
        reevaluatePolling()
    }

    private func scheduleConnectRetries() {
        for delay in HeadsetBatteryPolicy.connectRetries {
            let task = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled else { return }
                await self?.refreshNow()
            }
            retryTasks.append(task)
        }
    }

    // MARK: - Polling

    private func reevaluatePolling() {
        let should = HeadsetBatteryPolicy.shouldPoll(
            hasTarget: targetUID != nil,
            menuBarEnabled: settings?.showHeadsetBatteryInMenuBar ?? true,
            menuOpen: menuOpen
        )
        pollTask?.cancel()
        pollTask = nil
        guard should else { return }
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                let still = HeadsetBatteryPolicy.shouldPoll(
                    hasTarget: self.targetUID != nil,
                    menuBarEnabled: self.settings?.showHeadsetBatteryInMenuBar ?? true,
                    menuOpen: self.menuOpen
                )
                guard still else { break }
                await self.refreshNow()
                try? await Task.sleep(for: HeadsetBatteryPolicy.pollInterval)
            }
        }
    }

    private func refreshNow() async {
        guard let uid = targetUID,
              let address = BluetoothAddress.fromAudioUID(uid)
        else {
            clearIfStaleOrMissing()
            return
        }
        guard !inFlight else { return }
        inFlight = true
        defer { inFlight = false }

        let data = await Self.fetch()
        guard !Task.isCancelled else { return }

        guard let data,
              let report = BluetoothBatteryReport.parse(data),
              let found = report[address]
        else {
            log.notice("耳機電量查詢失敗或目標不在報告中：\(uid)")
            clearIfStaleOrMissing()
            return
        }
        battery = found
        lastSuccess = clock.now
    }

    private func clearIfStaleOrMissing() {
        if let lastSuccess, !HeadsetBatteryPolicy.isStale(age: clock.now - lastSuccess) {
            return
        }
        if battery != nil {
            battery = nil
        }
        lastSuccess = nil
    }

    // MARK: - system_profiler

    /// 背景跑 `system_profiler`；逾時 5 秒結束行程。不占用音量佇列。
    nonisolated static func fetch() async -> Data? {
        await Task.detached(priority: .utility) {
            runSystemProfiler()
        }.value
    }

    nonisolated private static func runSystemProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
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
        guard finished.wait(timeout: .now() + 5) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return data.isEmpty ? nil : data
    }

    private func installWakeObserver() {
        guard wakeObserver == nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    await self.refreshNow()
                }
            }
        }
    }
}
