import ChorusCore
import CoreGraphics
import Foundation

/// CoreGraphics 顯示模式列舉與套用（公開 API）。
@MainActor
final class DisplayModeClient {
    /// 目前模式；讀不到回 nil。
    func currentMode(for displayID: CGDirectDisplayID) -> DisplayModeDescriptor? {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
        return describe(mode)
    }

    /// 系統提供的全部模式（含低解析度重複項若系統允許）。
    func availableModes(for displayID: CGDirectDisplayID) -> [DisplayModeDescriptor] {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return []
        }
        return DisplayModeCatalog.dedupe(modes.map { describe($0) })
    }

    /// 是否處於鏡像組（第一版禁止對鏡像組寫入模式）。
    func isMirrored(_ displayID: CGDirectDisplayID) -> Bool {
        CGDisplayMirrorsDisplay(displayID) != kCGNullDirectDisplay
            || CGDisplayIsInMirrorSet(displayID) != 0
    }

    /// 以 `.forAppOnly` 套用模式。成功後讀回核對。
    @discardableResult
    func apply(
        _ descriptor: DisplayModeDescriptor,
        to displayID: CGDirectDisplayID
    ) -> Result<DisplayModeDescriptor, ApplyError> {
        guard !isMirrored(displayID) else { return .failure(.mirrored) }
        guard let cgMode = findCGMode(matching: descriptor, displayID: displayID) else {
            return .failure(.modeNotFound)
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            return .failure(.configurationFailed)
        }
        let configureStatus = CGConfigureDisplayWithDisplayMode(config, displayID, cgMode, nil)
        guard configureStatus == .success else {
            CGCancelDisplayConfiguration(config)
            return .failure(.configurationFailed)
        }
        let completeStatus = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard completeStatus == .success else {
            return .failure(.configurationFailed)
        }
        guard let actual = currentMode(for: displayID), actual.matches(descriptor) else {
            return .failure(.readbackMismatch)
        }
        return .success(actual)
    }

    enum ApplyError: Error, Equatable {
        case mirrored
        case modeNotFound
        case configurationFailed
        case readbackMismatch
    }

    private func describe(_ mode: CGDisplayMode) -> DisplayModeDescriptor {
        let logicalW = Int(mode.width)
        let logicalH = Int(mode.height)
        // 公開 API：pixel 尺寸；舊系統若與 logical 相同即非 HiDPI
        let pixelW = Int(mode.pixelWidth)
        let pixelH = Int(mode.pixelHeight)
        return DisplayModeDescriptor(
            logicalWidth: logicalW,
            logicalHeight: logicalH,
            pixelWidth: pixelW > 0 ? pixelW : logicalW,
            pixelHeight: pixelH > 0 ? pixelH : logicalH,
            refreshRate: mode.refreshRate,
            flags: mode.ioFlags
        )
    }

    private func findCGMode(
        matching descriptor: DisplayModeDescriptor,
        displayID: CGDirectDisplayID
    ) -> CGDisplayMode? {
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, nil) as? [CGDisplayMode] else {
            return nil
        }
        return modes.first { describe($0).matches(descriptor) }
    }
}
