import CoreGraphics
import Foundation

/// 所有 DDC/I2C 操作限制在單一 serial queue 上：
/// I2C 有嚴格時序（write 前 10ms、read 前 50ms、失敗重試），且 API 會阻塞執行緒，
/// 不能放進 Swift concurrency cooperative pool，也不能對同一顯示器並發。
/// queue 之外只暴露 async／fire-and-forget 介面；IOAVService 參照永不離開 queue。
final class DDCController: @unchecked Sendable {
    enum VCP {
        static let brightness: UInt8 = 0x10
        static let volume: UInt8 = 0x62
        static let mute: UInt8 = 0x8D
    }

    /// VCP 0x8D 的標準值：1 = mute、2 = unmute。
    enum MuteValue {
        static let muted: UInt16 = 1
        static let unmuted: UInt16 = 2
    }

    /// 連續寫入失敗達此次數即視為 DDC 不可用（轉接器不透傳 I2C、螢幕關閉 DDC/CI 等）。
    private static let writeFailureThreshold = 3

    // MARK: - 寫入節流參數
    //
    // 拖曳滑桿會產生每秒數十個值。實測（AG493US3R4）連續 I2C 會把螢幕 scaler
    // 打掛——畫面變雪花、只能硬重啟；兩台 Mac 同步時雙方各自寫入更危險。
    // 因此採「靜置才寫 + 最大延遲上限」：
    //   - 值停止變動 settleQuiet 後寫出最後值（拖曳結束必定落地）
    //   - 拖曳持續進行時，每 maxLatency 至少寫一次維持視覺回饋
    // 淨效果：持續拖曳約 2.5 Hz、結束後補一次，遠低於先前的 10 Hz。

    /// 值停止變動多久後寫出。
    private static let settleQuiet: TimeInterval = 0.15
    /// 持續拖曳時兩次寫入的最大間隔（視覺回饋下限）。
    private static let maxLatency: TimeInterval = 0.4
    /// 判斷上述兩條件的輪詢間隔。
    private static let tickInterval: TimeInterval = 0.05

    private let queue = DispatchQueue(label: "com.hermes.Chorus.ddc", qos: .userInitiated)

    // 以下狀態只在 queue 上讀寫
    private var services: [CGDirectDisplayID: IOAVService] = [:]
    private var pendingWrites: [CGDirectDisplayID: [UInt8: UInt16]] = [:]
    /// 每個 (display, vcp) 最後成功寫入的值：相同值不再打 I2C。
    private var lastWritten: [CGDirectDisplayID: [UInt8: UInt16]] = [:]
    private var tickScheduled = false
    private var lastRequestUptime: TimeInterval = 0
    private var lastFlushUptime: TimeInterval = 0
    private var writeFailureCounts: [CGDirectDisplayID: Int] = [:]
    private var failureHandler: (@Sendable (CGDirectDisplayID) -> Void)?

    /// 註冊「DDC 持續失敗」回呼（呼叫端負責降級到軟體調光）。
    func setPersistentFailureHandler(_ handler: @escaping @Sendable (CGDirectDisplayID) -> Void) {
        queue.async { self.failureHandler = handler }
    }

    /// 重新掃描 IORegistry 並配對 display ID ↔ IOAVService。
    /// 回傳有 DDC 能力的 display ID 集合。
    func refresh(displayIDs: [CGDirectDisplayID]) async -> Set<CGDirectDisplayID> {
        await withCheckedContinuation { continuation in
            queue.async {
                guard AppleSiliconDDC.isArm64 else {
                    self.services = [:]
                    continuation.resume(returning: [])
                    return
                }
                let matches = AppleSiliconDDC.getServiceMatches(displayIDs: displayIDs)
                var refreshed: [CGDirectDisplayID: IOAVService] = [:]
                for match in matches where !match.dummy && !match.discouraged {
                    if let service = match.service {
                        refreshed[match.displayID] = service
                    }
                }
                self.services = refreshed
                self.pendingWrites = [:]
                self.lastWritten = [:]
                self.writeFailureCounts = [:]
                continuation.resume(returning: Set(refreshed.keys))
            }
        }
    }

    /// 讀取 VCP 現值與最大值。讀取失敗（螢幕不支援或 I2C 錯誤）回 nil。
    func read(_ displayID: CGDirectDisplayID, vcp: UInt8) async -> (current: UInt16, max: UInt16)? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard let service = self.services[displayID] else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: AppleSiliconDDC.read(service: service, command: vcp))
            }
        }
    }

    /// 寫入 VCP 值。fire-and-forget：拖曳期間的連續值會合併，
    /// 依 §寫入節流參數 的規則稀疏寫出；與最後成功寫入相同的值完全不碰 I2C。
    func write(_ displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) {
        queue.async {
            if self.lastWritten[displayID]?[vcp] == value {
                // 值等同硬體現況：連 pending 都不用留（例如拖回原位、重複套用）
                self.pendingWrites[displayID]?[vcp] = nil
                if self.pendingWrites[displayID]?.isEmpty == true {
                    self.pendingWrites.removeValue(forKey: displayID)
                }
                return
            }
            self.pendingWrites[displayID, default: [:]][vcp] = value
            self.lastRequestUptime = ProcessInfo.processInfo.systemUptime
            self.scheduleTickLocked()
        }
    }

    /// 只能在 queue 上呼叫。輪詢檢查「已靜置」或「距上次寫入過久」，
    /// 兩者任一成立就把 pending 值寫出；仍有 pending 就繼續排下一次檢查。
    private func scheduleTickLocked() {
        guard !tickScheduled else { return }
        tickScheduled = true
        queue.asyncAfter(deadline: .now() + Self.tickInterval) {
            self.tickScheduled = false
            guard !self.pendingWrites.isEmpty else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let settled = now - self.lastRequestUptime >= Self.settleQuiet
            let overdue = now - self.lastFlushUptime >= Self.maxLatency
            if settled || overdue {
                self.flushLocked(now: now)
            }
            if !self.pendingWrites.isEmpty {
                self.scheduleTickLocked()
            }
        }
    }

    /// 只能在 queue 上呼叫。
    private func flushLocked(now: TimeInterval) {
        lastFlushUptime = now
        let batch = pendingWrites
        pendingWrites = [:]
        for (displayID, vcpValues) in batch {
            guard let service = services[displayID] else { continue }
            for (vcp, value) in vcpValues {
                if AppleSiliconDDC.write(service: service, command: vcp, value: value) {
                    writeFailureCounts[displayID] = 0
                    lastWritten[displayID, default: [:]][vcp] = value
                } else {
                    let failures = (writeFailureCounts[displayID] ?? 0) + 1
                    writeFailureCounts[displayID] = failures
                    if failures >= Self.writeFailureThreshold {
                        // DDC 確定不可用：移除服務讓後續寫入變 no-op，並通知降級
                        services.removeValue(forKey: displayID)
                        pendingWrites.removeValue(forKey: displayID)
                        lastWritten.removeValue(forKey: displayID)
                        failureHandler?(displayID)
                        break
                    }
                }
            }
        }
    }
}
