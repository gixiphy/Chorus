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
    /// 兩次 flush 之間的最小間隔。合併只保證「送最後值」，沒有間隔的話拖曳
    /// 期間仍會以每秒數十次打 I2C——部分螢幕 scaler／DCP 會被打掛
    /// （實測：連續 VCP 0x62 造成螢幕雪花、需硬重啟）。10 Hz 對 UI 足夠平滑。
    private static let minFlushInterval: TimeInterval = 0.1

    private let queue = DispatchQueue(label: "com.hermes.Chorus.ddc", qos: .userInitiated)

    // 以下狀態只在 queue 上讀寫
    private var services: [CGDirectDisplayID: IOAVService] = [:]
    private var pendingWrites: [CGDirectDisplayID: [UInt8: UInt16]] = [:]
    private var flushScheduled = false
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

    /// 寫入 VCP 值。fire-and-forget：slider 拖曳期間的連續寫入會自動合併，
    /// 只送出每個 (display, vcp) 的最後值。
    func write(_ displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16) {
        queue.async {
            self.pendingWrites[displayID, default: [:]][vcp] = value
            self.scheduleFlushLocked()
        }
    }

    /// 只能在 queue 上呼叫。把 flush 排到目前已入佇列的更新之後、且距離上次
    /// flush 至少 minFlushInterval，讓 pending 更新合併完再以受限頻率寫出。
    private func scheduleFlushLocked() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let elapsed = ProcessInfo.processInfo.systemUptime - lastFlushUptime
        let delay = max(0, Self.minFlushInterval - elapsed)
        queue.asyncAfter(deadline: .now() + delay) {
            self.flushScheduled = false
            self.lastFlushUptime = ProcessInfo.processInfo.systemUptime
            let batch = self.pendingWrites
            self.pendingWrites = [:]
            for (displayID, vcpValues) in batch {
                guard let service = self.services[displayID] else { continue }
                for (vcp, value) in vcpValues {
                    let success = AppleSiliconDDC.write(service: service, command: vcp, value: value)
                    if success {
                        self.writeFailureCounts[displayID] = 0
                    } else {
                        let failures = (self.writeFailureCounts[displayID] ?? 0) + 1
                        self.writeFailureCounts[displayID] = failures
                        if failures >= Self.writeFailureThreshold {
                            // DDC 確定不可用：移除服務讓後續寫入變 no-op，並通知降級
                            self.services.removeValue(forKey: displayID)
                            self.pendingWrites.removeValue(forKey: displayID)
                            self.failureHandler?(displayID)
                            break
                        }
                    }
                }
            }
        }
    }
}
