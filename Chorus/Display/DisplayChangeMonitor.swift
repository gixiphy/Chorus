import ChorusCore
import CoreGraphics
import Foundation

/// CoreGraphics 顯示組態變更監視。callback 只複製 display ID／flags，轉交主執行緒；
/// 不做 I2C 或其它阻塞工作。
@MainActor
final class DisplayChangeMonitor {
    struct Event: Sendable, Equatable {
        var displayID: CGDirectDisplayID
        var flags: CGDisplayChangeSummaryFlags
        var beginConfiguration: Bool

        var reasons: Set<DisplayRefreshPolicy.Reason> {
            var result: Set<DisplayRefreshPolicy.Reason> = []
            if beginConfiguration {
                result.insert(.configurationBegan)
                return result
            }
            if flags.contains(.addFlag) || flags.contains(.removeFlag)
                || flags.contains(.enabledFlag) || flags.contains(.disabledFlag)
                || flags.contains(.mirrorFlag) || flags.contains(.unMirrorFlag)
            {
                result.insert(.topologyChanged)
            }
            if flags.contains(.setModeFlag) || flags.contains(.setMainFlag)
                || flags.contains(.movedFlag) || flags.contains(.desktopShapeChangedFlag)
            {
                result.insert(.modeChanged)
            }
            if result.isEmpty {
                result.insert(.notification)
            }
            return result
        }
    }

    private var handler: (@MainActor (Event) -> Void)?
    private var registered = false

    func start(handler: @escaping @MainActor (Event) -> Void) {
        self.handler = handler
        guard !registered else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRegisterReconfigurationCallback(displayChangeMonitorCallback, pointer)
        registered = true
    }

    func stop() {
        guard registered else { return }
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CGDisplayRemoveReconfigurationCallback(displayChangeMonitorCallback, pointer)
        registered = false
        handler = nil
    }

    fileprivate func receive(displayID: CGDirectDisplayID, flags: CGDisplayChangeSummaryFlags) {
        let begin = flags.contains(.beginConfigurationFlag)
        let event = Event(displayID: displayID, flags: flags, beginConfiguration: begin)
        handler?(event)
    }
}

private func displayChangeMonitorCallback(
    display: CGDirectDisplayID,
    flags: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let monitor = Unmanaged<DisplayChangeMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    // CoreGraphics 可能在任意執行緒回呼；轉主執行緒再處理。
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            monitor.receive(displayID: display, flags: flags)
        }
    }
}
