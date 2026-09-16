import ChorusCore
import CoreGraphics
import Foundation
import Synchronization

/// 所有 DDC/I2C 操作限制在單一 serial queue 上：
/// I2C 有嚴格時序（write 前 10ms、read 前 50ms、失敗重試），且 API 會阻塞執行緒，
/// 不能放進 Swift concurrency cooperative pool，也不能對同一顯示器並發。
/// queue 之外只暴露 async／fire-and-forget 介面；IOAVService 參照永不離開 queue。
///
/// I2C 呼叫卡住時整條 queue 會跟著停：讀取與掃描因此**有期限**（到期回 nil／空集合，
/// 顯示器降級而不是整個列舉卡住），而 queue 上的工作卡過期限後，新的讀取直接回 nil、
/// 不再排進去。寫入在排進 queue 之前就合併（每個顯示器每個 VCP 只留最新值）。
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

    /// 讀取的等待期限（掃描另給 `refreshDeadline`）。期限只放開呼叫端，打斷不了 I2C。
    let readDeadline: Duration
    let refreshDeadline: Duration
    /// 診斷五個 VCP 的整體期限。
    let diagnosticsDeadline: Duration
    /// 測試用：在每個 queue 上的 I/O 之前呼叫（模擬 I2C 卡住）。
    private let ioHook: (@Sendable () -> Void)?
    private let origin = SuspendingClock.now
    /// 目前 queue 上那件工作從什麼時候開始跑（nil ＝ 閒著）。
    private let runningSince = Mutex<Duration?>(nil)
    /// 服務／拓撲世代：舊工作完成後不得覆蓋較新的服務表。
    private let serviceGeneration = Mutex<UInt64>(0)

    private struct WriteKey: Hashable, Sendable {
        let displayID: CGDirectDisplayID
        let vcp: UInt8
    }

    private struct RequestedWrite: Sendable {
        var value: UInt16
        var oneShot: Bool
    }

    /// 生產端信箱：還沒交給 queue 的寫入。
    private let requestedWrites = Mutex(LatestValueMailbox<WriteKey, RequestedWrite>())

    init(
        readDeadline: Duration = .seconds(3),
        refreshDeadline: Duration = .seconds(5),
        diagnosticsDeadline: Duration = .seconds(3),
        ioHook: (@Sendable () -> Void)? = nil
    ) {
        self.readDeadline = readDeadline
        self.refreshDeadline = refreshDeadline
        self.diagnosticsDeadline = diagnosticsDeadline
        self.ioHook = ioHook
    }

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
    private var failureHandler: (@Sendable (CGDirectDisplayID) -> Void)?

    private struct CachedDiagnosticsSnapshot: Sendable {
        var hasService: Bool
        var failureCounts: [UInt8: Int]
        var transport: (upstream: String, downstream: String)?
        var capturedAt: Duration
    }

    private let diagnosticsCache = Mutex<[CGDirectDisplayID: CachedDiagnosticsSnapshot]>([:])
    private let diagnosticsInFlight = Mutex<[CGDirectDisplayID: Bool]>([:])

    /// 所有投進 queue 的工作都經過這裡，排隊中的數量才量得到（`ddc.queue`）。
    /// I2C 卡住時整條 queue 停住，這個數字會一路往上。
    private func enqueue(_ work: @escaping @Sendable () -> Void) {
        OperationMetrics.shared.adjustGauge("ddc.queue", by: 1)
        queue.async {
            OperationMetrics.shared.adjustGauge("ddc.queue", by: -1)
            let started = self.origin.duration(to: .now)
            self.runningSince.withLock { $0 = started }
            work()
            self.runningSince.withLock { $0 = nil }
        }
    }

    /// queue 上的工作已經跑超過讀取期限：I2C 多半卡住了，新的讀取不必再排。
    private var isStuck: Bool {
        guard let started = runningSince.withLock({ $0 }) else { return false }
        return origin.duration(to: .now) - started > readDeadline
    }

    /// 音訊類 VCP（0x62/0x8D）持續失敗的回呼——只影響音量橋接，
    /// 絕不連坐亮度（見 flushLocked 的分 VCP 計數）。
    func setAudioFailureHandler(_ handler: @escaping @Sendable (CGDirectDisplayID) -> Void) {
        enqueue { self.audioFailureHandler = handler }
    }

    /// 註冊「DDC 持續失敗」回呼（呼叫端負責降級到軟體調光）。
    func setPersistentFailureHandler(_ handler: @escaping @Sendable (CGDirectDisplayID) -> Void) {
        enqueue { self.failureHandler = handler }
    }

    /// 目前服務世代（MainActor 刷新對帳用）。
    var currentGeneration: UInt64 {
        serviceGeneration.withLock { $0 }
    }

    /// 在 queue 上做事並等結果，最多 `deadline`；到期回 `fallback`，晚到的結果丟掉。
    /// `generation` 非 nil 時，執行前／提交前核對世代，過期則回 fallback。
    private func awaitQueue<T: Sendable>(
        _ name: String,
        deadline: Duration,
        fallback: T,
        generation: UInt64? = nil,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            let gate = DDCResultGate(continuation)
            let deadlineInstant = origin.duration(to: .now) + deadline
            enqueue {
                if self.origin.duration(to: .now) >= deadlineInstant {
                    _ = gate.resume(fallback)
                    return
                }
                if let generation, self.serviceGeneration.withLock({ $0 }) != generation {
                    _ = gate.resume(fallback)
                    return
                }
                self.ioHook?()
                let result = OperationMetrics.shared.measure(name, work)
                if let generation, self.serviceGeneration.withLock({ $0 }) != generation {
                    _ = gate.resume(fallback)
                    return
                }
                gate.resume(result)
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline.millis / 1_000) {
                if gate.resume(fallback) {
                    OperationMetrics.shared.end(OperationMetrics.shared.begin("\(name).timeout"), .timeout)
                }
            }
        }
    }

    /// 重新掃描 IORegistry 並配對 display ID ↔ IOAVService。
    /// 未變的服務保留 pending／lastWritten／失敗計數；真正替換時只失效該服務快取。
    /// 回傳有 DDC 能力的 display ID 集合。
    func refresh(displayIDs: [CGDirectDisplayID], generation: UInt64? = nil) async -> Set<CGDirectDisplayID> {
        let gen = generation ?? serviceGeneration.withLock { value in
            value &+= 1
            return value
        }
        if generation != nil {
            serviceGeneration.withLock { $0 = gen }
        }
        return await awaitQueue("ddc.refresh", deadline: refreshDeadline, fallback: [], generation: gen) {
            guard AppleSiliconDDC.isArm64 else {
                self.services = [:]
                self.pendingWrites = [:]
                self.lastWritten = [:]
                self.writeFailureCounts = [:]
                self.transports = [:]
                self.publishDiagnosticsCacheLocked()
                return []
            }
            let matches = AppleSiliconDDC.getServiceMatches(displayIDs: displayIDs)
            var refreshed: [CGDirectDisplayID: IOAVService] = [:]
            var newTransports: [CGDirectDisplayID: (upstream: String, downstream: String)] = [:]
            for match in matches where !match.dummy && !match.discouraged {
                if let service = match.service {
                    refreshed[match.displayID] = service
                    newTransports[match.displayID] = (
                        match.serviceDetails.transportUpstream,
                        match.serviceDetails.transportDownstream
                    )
                }
            }

            let oldIDs = Set(self.services.keys)
            let newIDs = Set(refreshed.keys)
            for id in oldIDs where !newIDs.contains(id) {
                self.pendingWrites.removeValue(forKey: id)
                self.lastWritten.removeValue(forKey: id)
                self.writeFailureCounts.removeValue(forKey: id)
            }
            self.services = refreshed
            self.transports = newTransports
            self.publishDiagnosticsCacheLocked()
            return newIDs
        }
    }

    /// 讀取 VCP 現值與最大值。讀取失敗（螢幕不支援或 I2C 錯誤）回 nil。
    func read(_ displayID: CGDirectDisplayID, vcp: UInt8) async -> (current: UInt16, max: UInt16)? {
        guard !isStuck else { return nil }
        return await awaitQueue("ddc.read", deadline: readDeadline, fallback: nil) {
            guard let service = self.services[displayID] else { return nil }
            return AppleSiliconDDC.read(service: service, command: vcp)
        }
    }

    /// 寫入 VCP 值。fire-and-forget：拖曳期間的連續值會合併，
    /// 依 §寫入節流參數 的規則稀疏寫出；與最後成功寫入相同的值完全不碰 I2C。
    ///
    /// `oneShot`：跳過「與最後寫入相同就不寫」的去重——輸入源這類動作型 VCP
    /// 可能被外部改走（螢幕按鈕、另一台機器），我們的 lastWritten 不可信。
    ///
    /// 同一個 (display, vcp) 在交給 queue 之前只留最新值；one-shot 標記合併時保留。
    func write(_ displayID: CGDirectDisplayID, vcp: UInt8, value: UInt16, oneShot: Bool = false) {
        let key = WriteKey(displayID: displayID, vcp: vcp)
        let request = RequestedWrite(value: value, oneShot: oneShot)
        let schedule = requestedWrites.withLock { mailbox in
            mailbox.put(request, for: key) { pending, new in
                RequestedWrite(value: new.value, oneShot: pending.oneShot || new.oneShot)
            }
        }
        if schedule {
            enqueue { self.ingestRequestedWritesLocked() }
        }
    }

    /// 只能在 queue 上呼叫。把信箱裡的寫入併進 pending（去重規則不變）。
    private func ingestRequestedWritesLocked() {
        for (key, request) in requestedWrites.withLock({ $0.take() }) {
            let displayID = key.displayID
            let vcp = key.vcp
            if request.oneShot {
                lastWritten[displayID]?[vcp] = nil
            }
            if lastWritten[displayID]?[vcp] == request.value {
                // 值等同硬體現況：連 pending 都不用留（例如拖回原位、重複套用）
                pendingWrites[displayID]?[vcp] = nil
                if pendingWrites[displayID]?.isEmpty == true {
                    pendingWrites.removeValue(forKey: displayID)
                }
                continue
            }
            pendingWrites[displayID, default: [:]][vcp] = request.value
            lastRequestUptime = ProcessInfo.processInfo.systemUptime
            scheduleTickLocked()
        }
    }

    /// 睡醒後螢幕的 I2C/scaler 需要時間才可靠：此期間所有寫入延後
    /// （pending 保留、值照常合併），期滿由 tick 自動補寫最後值。
    func deferWrites(for seconds: TimeInterval) {
        enqueue {
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
                let started = self.origin.duration(to: .now)
                self.runningSince.withLock { $0 = started }
                OperationMetrics.shared.measure("ddc.flush") { self.flushLocked(now: now) }
                self.runningSince.withLock { $0 = nil }
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
                self.ioHook?()
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
        publishDiagnosticsCacheLocked()
    }

    // MARK: - 診斷

    enum VCPReadStatus: Sendable, Equatable {
        case value(current: UInt16, max: UInt16)
        case unsupported
        case timedOut
        case skipped
        case notRead

        var tuple: (current: UInt16, max: UInt16)? {
            if case let .value(current, max) = self { return (current, max) }
            return nil
        }
    }

    struct Diagnostics: Sendable {
        let hasService: Bool
        let failureCounts: [UInt8: Int]
        let brightness: VCPReadStatus
        let contrast: VCPReadStatus
        let inputSource: VCPReadStatus
        let volume: VCPReadStatus
        let mute: VCPReadStatus
        /// IORegistry Transport（上游/下游）；DP→HDMI ＝ 轉換晶片、不透傳 DDC。
        let transport: (upstream: String, downstream: String)?
        let snapshotAge: Duration?
        let snapshotStale: Bool
        let incomplete: Bool
        let queueStuck: Bool
        /// EDID 摘要（不含完整序號／原始區塊）。
        let edid: EDIDSummary?
    }

    /// 設定頁「DDC 診斷」：快取服務快照立即提供；五個 VCP 共用整體期限。
    /// 同一顯示器同時只跑一份；queue 卡住時不再追加。
    func diagnostics(_ displayID: CGDirectDisplayID) async -> Diagnostics {
        let stuck = isStuck
        let cached = diagnosticsCache.withLock { $0[displayID] }
        let now = origin.duration(to: .now)
        let snapshotAge = cached.map { now - $0.capturedAt }
        let snapshotStale = snapshotAge.map { $0 > diagnosticsDeadline } ?? true

        if stuck {
            return Diagnostics(
                hasService: cached?.hasService ?? false,
                failureCounts: cached?.failureCounts ?? [:],
                brightness: .notRead,
                contrast: .notRead,
                inputSource: .notRead,
                volume: .notRead,
                mute: .notRead,
                transport: cached?.transport,
                snapshotAge: snapshotAge,
                snapshotStale: snapshotStale,
                incomplete: true,
                queueStuck: true,
                edid: nil
            )
        }

        let shouldRun = diagnosticsInFlight.withLock { inflight -> Bool in
            if inflight[displayID] == true { return false }
            inflight[displayID] = true
            return true
        }
        if !shouldRun {
            return Diagnostics(
                hasService: cached?.hasService ?? false,
                failureCounts: cached?.failureCounts ?? [:],
                brightness: .notRead,
                contrast: .notRead,
                inputSource: .notRead,
                volume: .notRead,
                mute: .notRead,
                transport: cached?.transport,
                snapshotAge: snapshotAge,
                snapshotStale: snapshotStale,
                incomplete: true,
                queueStuck: false,
                edid: nil
            )
        }
        defer { diagnosticsInFlight.withLock { $0[displayID] = false } }

        let snapshot: CachedDiagnosticsSnapshot = await awaitQueue(
            "ddc.diagnostics.snapshot",
            deadline: min(readDeadline, diagnosticsDeadline),
            fallback: cached ?? CachedDiagnosticsSnapshot(
                hasService: false,
                failureCounts: [:],
                transport: nil,
                capturedAt: now
            )
        ) {
            let snap = CachedDiagnosticsSnapshot(
                hasService: self.services[displayID] != nil,
                failureCounts: self.writeFailureCounts[displayID] ?? [:],
                transport: self.transports[displayID],
                capturedAt: self.origin.duration(to: .now)
            )
            self.diagnosticsCache.withLock { $0[displayID] = snap }
            return snap
        }

        let deadline = ContinuousClock.now.advanced(by: diagnosticsDeadline)
        var incomplete = false

        func readOne(_ vcp: UInt8) async -> VCPReadStatus {
            if ContinuousClock.now >= deadline {
                incomplete = true
                return .skipped
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard !isStuck else {
                incomplete = true
                return .timedOut
            }
            let value: (current: UInt16, max: UInt16)? = await withCheckedContinuation { continuation in
                let gate = DDCResultGate(continuation)
                let readDeadline = min(self.readDeadline, remaining)
                let deadlineInstant = self.origin.duration(to: .now) + readDeadline
                self.enqueue {
                    if self.origin.duration(to: .now) >= deadlineInstant {
                        _ = gate.resume(nil)
                        return
                    }
                    self.ioHook?()
                    let result: (current: UInt16, max: UInt16)?
                    if let service = self.services[displayID] {
                        result = OperationMetrics.shared.measure("ddc.read") {
                            AppleSiliconDDC.read(service: service, command: vcp)
                        }
                    } else {
                        result = nil
                    }
                    gate.resume(result)
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + readDeadline.millis / 1_000) {
                    if gate.resume(nil) {
                        OperationMetrics.shared.end(
                            OperationMetrics.shared.begin("ddc.read.timeout"),
                            .timeout
                        )
                    }
                }
            }
            if ContinuousClock.now >= deadline, value == nil {
                incomplete = true
                return .timedOut
            }
            if let value { return .value(current: value.current, max: value.max) }
            return .unsupported
        }

        let brightness = await readOne(VCP.brightness)
        let contrast = await readOne(VCP.contrast)
        let inputSource = await readOne(VCP.inputSource)
        let volume = await readOne(VCP.volume)
        let mute = await readOne(VCP.mute)

        let edid: EDIDSummary? = await awaitQueue(
            "ddc.diagnostics.edid",
            deadline: max(.milliseconds(100), min(readDeadline, max(.zero, ContinuousClock.now.duration(to: deadline)))),
            fallback: nil
        ) {
            guard let service = self.services[displayID] else { return nil }
            self.ioHook?()
            guard let bytes = AppleSiliconDDC.readEDID(service: service) else { return nil }
            return EDIDParser.parse(bytes)
        }

        let age = origin.duration(to: .now) - snapshot.capturedAt
        return Diagnostics(
            hasService: snapshot.hasService,
            failureCounts: snapshot.failureCounts,
            brightness: brightness,
            contrast: contrast,
            inputSource: inputSource,
            volume: volume,
            mute: mute,
            transport: snapshot.transport,
            snapshotAge: age,
            snapshotStale: age > diagnosticsDeadline,
            incomplete: incomplete,
            queueStuck: false,
            edid: edid
        )
    }

    /// 只能在 queue 上呼叫：把目前服務狀態寫進快取。
    private func publishDiagnosticsCacheLocked() {
        let now = origin.duration(to: .now)
        var cache: [CGDirectDisplayID: CachedDiagnosticsSnapshot] = [:]
        let ids = Set(services.keys).union(writeFailureCounts.keys).union(transports.keys)
        for id in ids {
            cache[id] = CachedDiagnosticsSnapshot(
                hasService: services[id] != nil,
                failureCounts: writeFailureCounts[id] ?? [:],
                transport: transports[id],
                capturedAt: now
            )
        }
        diagnosticsCache.withLock { $0 = cache }
    }
}

/// 完成與逾時兩條路只有先到的那條會 resume。
private final class DDCResultGate<T: Sendable>: Sendable {
    private let continuation: Mutex<CheckedContinuation<T, Never>?>

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = Mutex(continuation)
    }

    @discardableResult
    func resume(_ value: T) -> Bool {
        let taken = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        taken?.resume(returning: value)
        return taken != nil
    }
}
