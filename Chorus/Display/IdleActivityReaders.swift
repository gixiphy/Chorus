import ChorusCore
import CoreGraphics
import Foundation
import IOKit

/// 閒置秒數讀取：CG 與 HIDIdleTime 取有效來源的最小值。
/// 全部失敗或無效時回傳 `.nan`，policy 會保守不熄屏。
enum IdleActivityReaders {
    /// `kCGAnyInputEventType`（`~0`）：滑鼠、鍵盤、平板等任一輸入都算。
    private static let anyInputEvent = CGEventType(rawValue: ~UInt32(0))!

    static func combinedIdleSeconds() -> Double {
        var samples: [Double] = []
        let cg = cgIdleSeconds()
        if AgentIdleBlankPolicy.isValidIdleSeconds(cg) {
            samples.append(cg)
        }
        if let hid = hidIdleSeconds(), AgentIdleBlankPolicy.isValidIdleSeconds(hid) {
            samples.append(hid)
        }
        guard let minimum = samples.min() else { return .nan }
        return minimum
    }

    static func cgIdleSeconds() -> Double {
        CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEvent
        )
    }

    /// IOHIDSystem `HIDIdleTime`（奈秒）→ 秒。讀取失敗回傳 nil。
    static func hidIdleSeconds() -> Double? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOHIDSystem")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let unmanaged = IORegistryEntryCreateCFProperty(
            service,
            "HIDIdleTime" as CFString,
            kCFAllocatorDefault,
            0
        ) else {
            return nil
        }
        let value = unmanaged.takeRetainedValue()
        let nanoseconds: Double
        if let number = value as? NSNumber {
            nanoseconds = number.doubleValue
        } else {
            return nil
        }
        guard nanoseconds.isFinite, nanoseconds >= 0 else { return nil }
        return nanoseconds / 1_000_000_000
    }
}
