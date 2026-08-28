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
    /// 目前被 gamma 全黑的顯示器（M9 第三層關閉）。
    /// 全黑期間 setFactor 一律讓路——否則調亮度或 refresh 重套會把螢幕點回來。
    private var blackedOut: Set<CGDirectDisplayID> = []

    /// 此顯示器目前是否處於軟體調光中。
    /// 原始 table 只在 setFactor 真的調暗時才會被擷取、restore 時清掉，
    /// 因此「有快取」＝「我們正在調暗它」，可用來區分使用者實際調過的顯示器
    /// 與只是帶著初始佔位亮度、從未套用過調光的顯示器。
    func isDimming(_ displayID: CGDirectDisplayID) -> Bool {
        originals[displayID] != nil
    }

    nonisolated init() {
        // process 結束時還原所有顯示器的 ColorSync gamma（closure 無捕捉，可當 C 函式指標）
        atexit {
            CGDisplayRestoreColorSyncSettings()
        }
    }

    /// 此顯示器目前是否被 gamma 全黑（M9 電源鈕的保底層）。
    func isBlackedOut(_ displayID: CGDirectDisplayID) -> Bool {
        blackedOut.contains(displayID)
    }

    /// M9 第三層關閉：gamma table 全零。螢幕仍通電、只是完全沒有畫面。
    /// 與 setFactor 共用同一份原始 table 快取，解除後由呼叫端重套亮度。
    func setBlackout(_ on: Bool, for displayID: CGDirectDisplayID) {
        if on {
            guard let original = originals[displayID] ?? capture(displayID) else { return }
            blackedOut.insert(displayID)
            var zero = [CGGammaValue](repeating: 0, count: Int(original.sampleCount))
            CGSetDisplayTransferByTable(displayID, original.sampleCount, &zero, &zero, &zero)
        } else {
            guard blackedOut.remove(displayID) != nil else { return }
            restore(displayID)
        }
    }

    /// factor 1.0 = 不調光（還原原始 table）；愈低愈暗。
    /// 全黑中的顯示器完全不受影響（電源鈕的狀態優先於亮度）。
    func setFactor(_ factor: Double, for displayID: CGDirectDisplayID) {
        guard !blackedOut.contains(displayID) else { return }
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
        blackedOut.removeAll()
        for displayID in Array(originals.keys) {
            restore(displayID)
        }
    }

    /// 顯示器移除時丟棄快取的 table（不嘗試還原已消失的顯示器）。
    func forget(_ displayID: CGDirectDisplayID) {
        originals.removeValue(forKey: displayID)
        blackedOut.remove(displayID)
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
