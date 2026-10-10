import ChorusCore
import Foundation
import IOKit.ps
import Observation

/// 電源／溫度取樣。測試可注入假的監聽器，不必碰 IOKit。
@MainActor
protocol PowerSourceObserving: AnyObject {
    var snapshot: PowerSnapshot { get }
    var onChange: (() -> Void)? { get set }
    func start()
    func stop()
}

/// 內建電池與系統溫度的監聽。
///
/// 電量靠 `IOPSNotificationCreateRunLoopSource`；溫度靠
/// `ProcessInfo.thermalStateDidChangeNotification`。兩者都無需權限。
@MainActor
@Observable
final class PowerSourceMonitor: PowerSourceObserving {
    private(set) var snapshot: PowerSnapshot

    @ObservationIgnored var onChange: (() -> Void)?

    @ObservationIgnored private var powerLoopSource: CFRunLoopSource?
    @ObservationIgnored private var thermalObserver: NSObjectProtocol?
    @ObservationIgnored private var running = false
    @ObservationIgnored private let readSnapshot: () -> PowerSnapshot
    @ObservationIgnored private let notificationCenter: NotificationCenter

    init(
        readSnapshot: @escaping () -> PowerSnapshot = PowerSourceMonitor.readSystemSnapshot,
        notificationCenter: NotificationCenter = .default
    ) {
        self.readSnapshot = readSnapshot
        self.notificationCenter = notificationCenter
        self.snapshot = readSnapshot()
    }

    func start() {
        guard !running else { return }
        running = true
        refresh()
        installPowerSourceNotifications()
        thermalObserver = notificationCenter.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stop() {
        guard running else { return }
        running = false
        if let powerLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerLoopSource, .defaultMode)
            self.powerLoopSource = nil
        }
        if let thermalObserver {
            notificationCenter.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
    }

    /// 測試縫：直接餵一筆快照並觸發 `onChange`。
    func ingestForTesting(_ snapshot: PowerSnapshot) {
        apply(snapshot)
    }

    private func refresh() {
        apply(readSnapshot())
    }

    private func apply(_ next: PowerSnapshot) {
        let previous = snapshot
        snapshot = next
        guard next != previous else { return }
        onChange?()
    }

    private func installPowerSourceNotifications() {
        guard powerLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self)
        guard let source = IOPSNotificationCreateRunLoopSource({ info in
            guard let info else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(info).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh() }
        }, context.toOpaque())?.takeRetainedValue() else {
            ChorusLog.display.error("IOPSNotificationCreateRunLoopSource failed")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerLoopSource = source
    }

    /// 讀系統目前的內建電池與溫度。沒有內建電池（Mac mini）時
    /// `hasInternalBattery` 為 false，電量底線不適用。
    nonisolated static func readSystemSnapshot() -> PowerSnapshot {
        let thermal = ProcessInfo.processInfo.thermalState
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else {
            return PowerSnapshot(
                hasInternalBattery: false, onBattery: nil, percent: nil, thermal: thermal
            )
        }

        var hasInternalBattery = false
        var onBattery: Bool?
        var percent: Int?

        for source in list {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any]
            else { continue }
            let type = description[kIOPSTypeKey] as? String
            guard type == kIOPSInternalBatteryType else { continue }
            hasInternalBattery = true

            if let state = description[kIOPSPowerSourceStateKey] as? String {
                if state == kIOPSBatteryPowerValue {
                    onBattery = true
                } else if state == kIOPSACPowerValue {
                    onBattery = false
                }
            }

            if let current = description[kIOPSCurrentCapacityKey] as? Int {
                let raw: Int
                if let max = description[kIOPSMaxCapacityKey] as? Int, max > 0, max != 100 {
                    raw = Int((Double(current) / Double(max) * 100).rounded())
                } else {
                    raw = current
                }
                percent = min(100, max(0, raw))
            }
        }

        return PowerSnapshot(
            hasInternalBattery: hasInternalBattery,
            onBattery: onBattery,
            percent: percent,
            thermal: thermal
        )
    }
}
