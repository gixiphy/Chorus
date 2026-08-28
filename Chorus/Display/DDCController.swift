import CoreGraphics
import Foundation

/// 所有 DDC/I2C 操作限制在單一 serial queue 上：
/// I2C 有嚴格時序（write 前 10ms、read 前 50ms、失敗重試），且 API 會阻塞執行緒，
/// 不能放進 Swift concurrency cooperative pool，也不能對同一顯示器並發。
/// queue 之外只暴露 async／fire-and-forget 介面；IOAVService 參照永不離開 queue。
final class DDCController: @unchecked Sendable {
    enum VCP {
        static let brightness: UInt8 = 0x10
        static let contrast: UInt8 = 0x12
        static let inputSource: UInt8 = 0x60
        static let volume: UInt8 = 0x62
        static let mute: UInt8 = 0x8D
        /// Power Mode。值見 `DisplayPowerValue`（只寫 on/off，永不寫 hard off）。
        static let power: UInt8 = 0xD6
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
    /// 失敗計數分 VCP（音訊 VCP 失敗不連坐亮度）。
    private var writeFailureCounts: [CGDirectDisplayID: [UInt8: Int]] = [:]
    /// 各顯示器的傳輸路徑（IORegistry Transport；診斷用）。
    /// 上游 DisplayPort＋下游 HDMI ＝ 內建 HDMI 埠／DP→HDMI 轉接的
    /// MCDP 類轉換晶片指紋——已知不透傳標準 DDC（Lunar 以隱藏碼特判此晶片）。
    private var transports: [CGDirectDisplayID: (upstream: String, downstream: String)] = [:]
    private var tickScheduled = false
    private var lastRequestUptime: TimeInterval = 0
    private var lastFlushUptime: TimeInterval = 0
    /// 此時間點（uptime）之前不打 I2C 寫入（睡醒靜置期；pending 保留、期滿補寫）。
    private var suspendUntilUptime: TimeInterval = 0
    private var audioFailureHandler: (@Sendable (CGDirectDisplayID) -> Void)?

    /// 音訊類 VCP（0x62/0x8D）持續失敗的回呼——只影響音量橋接，
    /// 絕不連坐亮度（見 flushLocked 的分 VCP 計數）。
    func setAudioFailureHandler(_ handler: @escaping @Sendable (CGDirectDisplayID) -> Void) {
        queue.async { self.audioFailureHandler = handler }
    }
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
                self.transports = [:]
                for match in matches where !match.dummy && !match.discouraged {
                    if let service = match.service {
                        refreshed[match.displayID] = service
                        self.transports[match.displayID] = (
                            match.serviceDetails.transportUpstream,
                            match.serviceDetails.transportDownstream
                        )
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
    ///
    /// `oneShot`：跳過「與最後寫入相同就不寫」的去重——輸入源這類動作型 VCP
    /// 可能被外部改走（螢幕按鈕、另一台機器），我們的 lastWritten 不可信。
    func write(_ displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16, oneShot: Bool = false) {
        queue.async {
            if oneShot {
                self.lastWritten[displayID]?[vcp] = nil
            }
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

    /// 睡醒後螢幕的 I2C/scaler 需要時間才可靠：此期間所有寫入延後
    /// （pending 保留、值照常合併），期滿由 tick 自動補寫最後值。
    func deferWrites(for seconds: TimeInterval) {
        queue.async {
            let until = ProcessInfo.processInfo.systemUptime + seconds
            self.suspendUntilUptime = max(self.suspendUntilUptime, until)
            if !self.pendingWrites.isEmpty {
                self.scheduleTickLocked()
            }
        }
    }

    /// 只能在 queue 上呼叫。輪詢檢查「已靜置」或「距上次寫入過久」，
    /// 兩者任一成立就把 pending 值寫出；仍有 pending 就繼續排下一次檢查。
    /// 睡醒靜置期（suspendUntilUptime）內不寫，只持續輪詢等解除。
    private func scheduleTickLocked() {
        guard !tickScheduled else { return }
        tickScheduled = true
        queue.asyncAfter(deadline: .now() + Self.tickInterval) {
            self.tickScheduled = false
            guard !self.pendingWrites.isEmpty else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let suspended = now < self.suspendUntilUptime
            let settled = now - self.lastRequestUptime >= Self.settleQuiet
            let overdue = now - self.lastFlushUptime >= Self.maxLatency
            if !suspended, settled || overdue {
                self.flushLocked(now: now)
            }
            if !self.pendingWrites.isEmpty {
                self.scheduleTickLocked()
            }
        }
    }

    /// 只能在 queue 上呼叫。失敗計數**分 VCP**：
    /// 亮度（0x10）連續失敗才代表 DDC 通道死了（降級整台）；
    /// 音訊 VCP（0x62/0x8D）失敗只代表螢幕不支援該指令，
    /// 只通知音訊層停用橋接——b16 曾因共用計數讓靜音寫入連坐處死亮度。
    private func flushLocked(now: TimeInterval) {
        lastFlushUptime = now
        let batch = pendingWrites
        pendingWrites = [:]
        for (displayID, vcpValues) in batch {
            guard let service = services[displayID] else { continue }
            for (vcp, value) in vcpValues {
                if AppleSiliconDDC.write(service: service, command: vcp, value: value) {
                    writeFailureCounts[displayID]?[vcp] = 0
                    lastWritten[displayID, default: [:]][vcp] = value
                } else {
                    let failures = (writeFailureCounts[displayID]?[vcp] ?? 0) + 1
                    writeFailureCounts[displayID, default: [:]][vcp] = failures
                    guard failures >= Self.writeFailureThreshold else { continue }
                    if vcp == VCP.brightness {
                        // DDC 通道確定不可用：移除服務讓後續寫入變 no-op，並通知降級
                        services.removeValue(forKey: displayID)
                        pendingWrites.removeValue(forKey: displayID)
                        lastWritten.removeValue(forKey: displayID)
                        failureHandler?(displayID)
                        break
                    } else {
                        pendingWrites[displayID]?[vcp] = nil
                        // 只有音訊 VCP 的失敗才通知音量橋接；輸入源／對比失敗
                        // 是各自的功能不支援，與橋接無關
                        if vcp == VCP.volume || vcp == VCP.mute {
                            audioFailureHandler?(displayID)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 診斷

    struct Diagnostics: Sendable {
        let hasService: Bool
        let failureCounts: [UInt8: Int]
        let brightness: (current: UInt16, max: UInt16)?
        let contrast: (current: UInt16, max: UInt16)?
        let inputSource: (current: UInt16, max: UInt16)?
        let volume: (current: UInt16, max: UInt16)?
        let mute: (current: UInt16, max: UInt16)?
        /// IORegistry Transport（上游/下游）；DP→HDMI ＝ 轉換晶片、不透傳 DDC。
        let transport: (upstream: String, downstream: String)?
    }

    /// 設定頁「DDC 診斷」：服務配對狀態＋五個 VCP 的讀值＋失敗計數。
    /// 純讀取，不寫入。
    func diagnostics(_ displayID: CGDirectDisplayID) async -> Diagnostics {
        let (hasService, failures, transport) = await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: (
                    self.services[displayID] != nil,
                    self.writeFailureCounts[displayID] ?? [:],
                    self.transports[displayID]
                ))
            }
        }
        let brightness = await read(displayID, vcp: VCP.brightness)
        let contrast = await read(displayID, vcp: VCP.contrast)
        let inputSource = await read(displayID, vcp: VCP.inputSource)
        let volume = await read(displayID, vcp: VCP.volume)
        let mute = await read(displayID, vcp: VCP.mute)
        return Diagnostics(
            hasService: hasService,
            failureCounts: failures,
            brightness: brightness,
            contrast: contrast,
            inputSource: inputSource,
            volume: volume,
            mute: mute,
            transport: transport
        )
    }
}
