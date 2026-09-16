import CoreGraphics
import Foundation

/// gamma table 軟體調光。DDC 與 DisplayServices 都不可用（或使用者強制）時的 fallback。
/// 以「目前 gamma table × 係數」的方式套用，避免蓋掉 f.lux 類軟體的色溫調整。
/// 注意：process 結束時 gamma 會自動重設；另外註冊 atexit 保險。
@MainActor
final class GammaDimmer {
    enum ApplyError: Error, Equatable {
        case captureFailed
        case writeFailed
        case invalidCapacity
    }

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
    /// 最後成功套用的係數（1.0＝已還原／未調暗）。診斷與喚醒後重套用。
    private var lastAppliedFactor: [CGDirectDisplayID: Double] = [:]
    private var lastFailureReason: [CGDirectDisplayID: ApplyError] = [:]

    /// 此顯示器目前是否處於軟體調光中。
    /// 原始 table 只在 setFactor 真的調暗且寫入成功時才會保留，
    /// 因此「有快取」＝「我們正在調暗它」。
    func isDimming(_ displayID: CGDirectDisplayID) -> Bool {
        originals[displayID] != nil
    }

    func lastFailure(for displayID: CGDirectDisplayID) -> ApplyError? {
        lastFailureReason[displayID]
    }

    nonisolated init() {
        atexit {
            CGDisplayRestoreColorSyncSettings()
        }
    }

    func isBlackedOut(_ displayID: CGDirectDisplayID) -> Bool {
        blackedOut.contains(displayID)
    }

    /// M9 第三層關閉：gamma table 全零。成功後才更改「已套用」狀態。
    @discardableResult
    func setBlackout(_ on: Bool, for displayID: CGDirectDisplayID) -> Result<Void, ApplyError> {
        if on {
            let captured: OriginalTable
            if let existing = originals[displayID] {
                captured = existing
            } else {
                switch capture(displayID) {
                case .success(let table):
                    captured = table
                case .failure(let error):
                    lastFailureReason[displayID] = error
                    return .failure(error)
                }
            }
            var zero = [CGGammaValue](repeating: 0, count: Int(captured.sampleCount))
            let status = OperationMetrics.shared.measure("display.gamma") {
                CGSetDisplayTransferByTable(displayID, captured.sampleCount, &zero, &zero, &zero)
            }
            guard status == .success else {
                lastFailureReason[displayID] = .writeFailed
                return .failure(.writeFailed)
            }
            originals[displayID] = captured
            blackedOut.insert(displayID)
            lastAppliedFactor[displayID] = 0
            lastFailureReason.removeValue(forKey: displayID)
            return .success(())
        } else {
            guard blackedOut.remove(displayID) != nil else { return .success(()) }
            return restore(displayID)
        }
    }

    /// factor 1.0 = 不調光；成功後才更新「已套用」狀態。
    @discardableResult
    func setFactor(_ factor: Double, for displayID: CGDirectDisplayID) -> Result<Void, ApplyError> {
        guard !blackedOut.contains(displayID) else { return .success(()) }
        if factor >= 0.999 {
            return restore(displayID)
        }
        let original: OriginalTable
        if let existing = originals[displayID] {
            original = existing
        } else {
            switch capture(displayID) {
            case .success(let table):
                original = table
            case .failure(let error):
                lastFailureReason[displayID] = error
                return .failure(error)
            }
        }
        let scale = CGGammaValue(min(max(factor, 0.05), 1))
        var red = original.red.map { $0 * scale }
        var green = original.green.map { $0 * scale }
        var blue = original.blue.map { $0 * scale }
        let status = OperationMetrics.shared.measure("display.gamma") {
            CGSetDisplayTransferByTable(displayID, original.sampleCount, &red, &green, &blue)
        }
        guard status == .success else {
            lastFailureReason[displayID] = .writeFailed
            if lastAppliedFactor[displayID] == nil {
                originals.removeValue(forKey: displayID)
            }
            return .failure(.writeFailed)
        }
        originals[displayID] = original
        lastAppliedFactor[displayID] = Double(scale)
        lastFailureReason.removeValue(forKey: displayID)
        return .success(())
    }

    /// 還原原始 table。寫入失敗時**保留**快取，以便下次再試。
    @discardableResult
    func restore(_ displayID: CGDirectDisplayID) -> Result<Void, ApplyError> {
        guard let original = originals[displayID] else { return .success(()) }
        var red = original.red
        var green = original.green
        var blue = original.blue
        let status = OperationMetrics.shared.measure("display.gamma") {
            CGSetDisplayTransferByTable(displayID, original.sampleCount, &red, &green, &blue)
        }
        guard status == .success else {
            lastFailureReason[displayID] = .writeFailed
            return .failure(.writeFailed)
        }
        originals.removeValue(forKey: displayID)
        lastAppliedFactor.removeValue(forKey: displayID)
        lastFailureReason.removeValue(forKey: displayID)
        return .success(())
    }

    func restoreAll() {
        blackedOut.removeAll()
        for displayID in Array(originals.keys) {
            _ = restore(displayID)
        }
    }

    func forget(_ displayID: CGDirectDisplayID) {
        originals.removeValue(forKey: displayID)
        blackedOut.remove(displayID)
        lastAppliedFactor.removeValue(forKey: displayID)
        lastFailureReason.removeValue(forKey: displayID)
    }

    private func capture(_ displayID: CGDirectDisplayID) -> Result<OriginalTable, ApplyError> {
        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity > 0, capacity <= 16_384 else {
            return .failure(.invalidCapacity)
        }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = [CGGammaValue](repeating: 0, count: Int(capacity))
        var blue = [CGGammaValue](repeating: 0, count: Int(capacity))
        var sampleCount: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &sampleCount) == .success,
              sampleCount > 0,
              sampleCount <= capacity
        else {
            return .failure(.captureFailed)
        }
        return .success(OriginalTable(
            red: Array(red.prefix(Int(sampleCount))),
            green: Array(green.prefix(Int(sampleCount))),
            blue: Array(blue.prefix(Int(sampleCount))),
            sampleCount: sampleCount
        ))
    }
}
