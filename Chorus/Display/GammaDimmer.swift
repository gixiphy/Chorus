import CoreGraphics
import Foundation

/// gamma table 軟體調光。DDC 與 DisplayServices 都不可用（或使用者強制）時的 fallback。
/// 以「目前 gamma table × 係數」的方式套用，避免蓋掉 f.lux 類軟體的色溫調整。
/// 注意：process 結束時 gamma 會自動重設；另外註冊 atexit 保險。
@MainActor
final class GammaDimmer {
    private struct OriginalTable {
        let red: [CGGammaValue]
        let green: [CGGammaValue]
        let blue: [CGGammaValue]
        let sampleCount: UInt32
    }

    private var originals: [CGDirectDisplayID: OriginalTable] = [:]

    nonisolated init() {
        // process 結束時還原所有顯示器的 ColorSync gamma（closure 無捕捉，可當 C 函式指標）
        atexit {
            CGDisplayRestoreColorSyncSettings()
        }
    }

    /// factor 1.0 = 不調光（還原原始 table）；愈低愈暗。
    func setFactor(_ factor: Double, for displayID: CGDirectDisplayID) {
        if factor >= 0.999 {
            restore(displayID)
            return
        }
        guard let original = originals[displayID] ?? capture(displayID) else { return }
        let scale = CGGammaValue(min(max(factor, 0.05), 1))
        var red = original.red.map { $0 * scale }
        var green = original.green.map { $0 * scale }
        var blue = original.blue.map { $0 * scale }
        CGSetDisplayTransferByTable(displayID, original.sampleCount, &red, &green, &blue)
    }

    func restore(_ displayID: CGDirectDisplayID) {
        guard let original = originals.removeValue(forKey: displayID) else { return }
        var red = original.red
        var green = original.green
        var blue = original.blue
        CGSetDisplayTransferByTable(displayID, original.sampleCount, &red, &green, &blue)
    }

    func restoreAll() {
        for displayID in Array(originals.keys) {
            restore(displayID)
        }
    }

    /// 顯示器移除時丟棄快取的 table（不嘗試還原已消失的顯示器）。
    func forget(_ displayID: CGDirectDisplayID) {
        originals.removeValue(forKey: displayID)
    }

    private func capture(_ displayID: CGDirectDisplayID) -> OriginalTable? {
        let capacity: UInt32 = 256
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = [CGGammaValue](repeating: 0, count: Int(capacity))
        var blue = [CGGammaValue](repeating: 0, count: Int(capacity))
        var sampleCount: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &sampleCount) == .success,
              sampleCount > 0
        else {
            return nil
        }
        let table = OriginalTable(
            red: Array(red.prefix(Int(sampleCount))),
            green: Array(green.prefix(Int(sampleCount))),
            blue: Array(blue.prefix(Int(sampleCount))),
            sampleCount: sampleCount
        )
        originals[displayID] = table
        return table
    }
}
