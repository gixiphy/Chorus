import ChorusCore
import Foundation
import Testing
@testable import Chorus

/// Batch A 的量測與故障注入接縫：故障真的會發生、量得到，而且各測試用各自的
/// registry／metrics，不動 `.shared`（test host 本身的 App 正在用它們）。
@Suite("回應性基線：故障注入")
struct FaultRegistryTests {
    @Test("fail 立刻丟錯；解除後恢復正常")
    func failThenClear() throws {
        let faults = FaultRegistry()
        faults.set(.cloudWrite, .fail)
        #expect(throws: FaultRegistry.InjectedFault(point: .cloudWrite)) {
            try faults.injectBlocking(.cloudWrite)
        }
        faults.set(.cloudWrite, nil)
        try faults.injectBlocking(.cloudWrite)
    }

    @Test("delay 會阻塞呼叫端執行緒約指定時間")
    func delayBlocks() throws {
        let faults = FaultRegistry()
        faults.set(.cloudRead, .delay(.milliseconds(200)))
        let started = ContinuousClock.now
        try faults.injectBlocking(.cloudRead)
        #expect(ContinuousClock.now - started >= .milliseconds(190))
    }

    @Test("hang 卡到被別的執行緒解除為止，不必等安全上限")
    func hangReleasedByClear() throws {
        let faults = FaultRegistry(hangLimit: .seconds(30))
        faults.set(.cloudScan, .hang)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
            faults.set(.cloudScan, nil)
        }
        let started = ContinuousClock.now
        try faults.injectBlocking(.cloudScan)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("非同步 hang 解除後繼續；withhold 只是查詢不阻塞")
    func asyncHangAndWithhold() async throws {
        let faults = FaultRegistry(hangLimit: .seconds(30))
        faults.set(.syncSend, .hang)
        let task = Task { try await faults.inject(.syncSend) }
        try await Task.sleep(for: .milliseconds(150))
        faults.set(.syncSend, nil)
        try await task.value

        faults.set(.syncHello, .withhold)
        #expect(faults.isWithholding(.syncHello))
        try await faults.inject(.syncHello)
    }

    @Test("apply(spec:) 解析失敗不改狀態")
    func applySpec() {
        let faults = FaultRegistry()
        #expect(faults.apply(spec: "sync.hello=withhold"))
        #expect(!faults.apply(spec: "sync.hello=fail"))
        #expect(faults.behavior(for: .syncHello) == .withhold)
    }
}

@Suite("回應性基線：操作計量")
struct OperationMetricsTests {
    @Test("measure 記成功與失敗；measureAsync 記取消")
    func outcomes() async {
        let metrics = OperationMetrics(log: nil)
        metrics.measure("op") {}
        _ = try? metrics.measure("op") { throw CocoaError(.fileNoSuchFile) }
        let task = Task {
            try await metrics.measureAsync("wait") { try await Task.sleep(for: .seconds(30)) }
        }
        task.cancel()
        _ = await task.result

        let snapshot = metrics.snapshot()
        #expect(snapshot.operations["op"]?.outcomes[.success] == 1)
        #expect(snapshot.operations["op"]?.outcomes[.failure] == 1)
        #expect(snapshot.operations["wait"]?.outcomes[.cancelled] == 1)
        #expect(snapshot.operations["wait"]?.inFlight == 0)
    }

    @Test("在途中的操作看得到年齡")
    func inFlightAge() async throws {
        let metrics = OperationMetrics(log: nil)
        let token = metrics.begin("sync.hello")
        try await Task.sleep(for: .milliseconds(50))
        #expect((metrics.snapshot().oldestInFlight["sync.hello"] ?? .zero) >= .milliseconds(40))
        #expect(metrics.collectNewStalls(threshold: .milliseconds(10)).map(\.name) == ["sync.hello"])
        metrics.end(token)
        #expect(metrics.snapshot().oldestInFlight.isEmpty)
    }
}

/// Batch B：備份 I/O 離開主執行緒。故障用各自的 registry 注入，時間參數縮到毫秒級。
@MainActor
@Suite("備份 I/O 卡住時的行為")
struct CloudBackupFaultTests {
    /// CloudBackup 以 unowned 參照 SceneStore——stores 要由呼叫端留著。
    private struct Fixture {
        let backup: CloudBackup
        let settings: SettingsStore
        let scenes: SceneStore
        let root: URL
        let faults: FaultRegistry
        let metrics: OperationMetrics

        var deviceFile: URL { root.appending(path: "devices/測試 Mac.json") }

        func writtenFocusDuration() -> Double? {
            (try? Data(contentsOf: deviceFile))
                .flatMap { try? BackupCodec.decode(DeviceBackup.self, from: $0) }?
                .focusLastDuration
        }
    }

    private static let fastTiming = CloudBackup.Timing(
        writeDeadline: .milliseconds(200),
        readDeadline: .milliseconds(200),
        tickInterval: .seconds(3_600),
        retryBase: .milliseconds(50),
        retryMax: .milliseconds(200)
    )

    private func makeFixture(timing: CloudBackup.Timing = fastTiming) -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "chorus-backup-fault-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "cloud-backup-fault-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let scenes = SceneStore(defaults: defaults)
        let faults = FaultRegistry(hangLimit: .seconds(10))
        let metrics = OperationMetrics(log: nil)
        let backup = CloudBackup(
            files: CloudBackupFiles(
                location: .fixed(root), deviceName: "測試 Mac", deviceID: "device-A",
                faults: faults, metrics: metrics
            ),
            settings: settings,
            scenes: scenes,
            timing: timing
        )
        return Fixture(backup: backup, settings: settings, scenes: scenes, root: root,
                       faults: faults, metrics: metrics)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func writeStats(_ f: Fixture) -> OperationStats? {
        f.metrics.snapshot().operations["cloud.write"]
    }

    @Test("寫入故障 → 備份回報失敗，計量記一次 cloud.write 失敗")
    func writeFailure() async {
        let f = makeFixture()
        f.faults.set(.cloudWrite, .fail)

        #expect(!(await f.backup.backupNow()))
        guard case .failed = f.backup.status else {
            Issue.record("status 應為 failed，實際 \(f.backup.status)")
            return
        }
        #expect(writeStats(f)?.outcomes[.failure] == 1)
    }

    @Test("寫入卡住：backupNow 在期限內返回、主執行緒照常執行，狀態是稍後重試")
    func hungWriteDoesNotBlock() async {
        let f = makeFixture()
        f.faults.set(.cloudWrite, .hang)
        defer { f.faults.set(.cloudWrite, nil) }

        var mainRan = false
        Task { @MainActor in mainRan = true }
        let started = ContinuousClock.now
        #expect(!(await f.backup.backupNow()))
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(mainRan)
        guard case .deferred = f.backup.status else {
            Issue.record("status 應為 deferred，實際 \(f.backup.status)")
            return
        }
    }

    @Test("卡住期間再要求備份不會追加 I/O：同時最多一件寫入")
    func hungWriteIsNotStacked() async {
        let f = makeFixture()
        f.faults.set(.cloudWrite, .hang)
        defer { f.faults.set(.cloudWrite, nil) }

        #expect(!(await f.backup.backupNow()))
        f.settings.focusLastDuration = 42
        let started = ContinuousClock.now
        #expect(!(await f.backup.backupNow()))
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(writeStats(f)?.started == 1)
        #expect(writeStats(f)?.inFlightHighWater == 1)
    }

    @Test("解除故障後自動重試，寫出的是最新一版")
    func retriesWithLatestAfterRecovery() async {
        let f = makeFixture()
        f.faults.set(.cloudWrite, .hang)
        #expect(!(await f.backup.backupNow()))
        f.settings.focusLastDuration = 1_234
        _ = await f.backup.backupNow()

        f.faults.set(.cloudWrite, nil)
        #expect(await waitUntil { f.writtenFocusDuration() == 1_234 })
        #expect(await waitUntil {
            if case .ok = f.backup.status { return true }
            return false
        })
    }

    @Test("舊版晚完成不會蓋掉新版；寫完新版之後內容沒變就不再寫")
    func olderWriteDoesNotWinOverNewer() async {
        let f = makeFixture(timing: .init(
            writeDeadline: .seconds(5), readDeadline: .seconds(5), tickInterval: .seconds(3_600),
            retryBase: .milliseconds(50), retryMax: .milliseconds(200)
        ))
        f.settings.cloudBackupEnabled = true
        f.faults.set(.cloudWrite, .delay(.milliseconds(300)))
        f.settings.focusLastDuration = 1
        let first = Task { await f.backup.backupNow() }
        #expect(await waitUntil { writeStats(f)?.inFlight == 1 })

        f.settings.focusLastDuration = 2
        let second = Task { await f.backup.backupNow() }
        #expect(await first.value)
        #expect(await second.value)
        #expect(f.writtenFocusDuration() == 2)
        #expect(writeStats(f)?.started == 2)

        await f.backup.tick()
        #expect(writeStats(f)?.started == 2)
    }

    @Test("結束時不等卡住的寫入")
    func shutdownDoesNotWaitForHungWrite() async {
        let f = makeFixture(timing: .init(
            writeDeadline: .seconds(30), readDeadline: .seconds(30), tickInterval: .seconds(3_600),
            retryBase: .milliseconds(50), retryMax: .milliseconds(200)
        ))
        f.faults.set(.cloudWrite, .hang)
        defer { f.faults.set(.cloudWrite, nil) }
        let pending = Task { await f.backup.backupNow() }
        #expect(await waitUntil { writeStats(f)?.inFlight == 1 })

        let started = ContinuousClock.now
        f.backup.shutdown()
        #expect(ContinuousClock.now - started < .milliseconds(100))
        #expect(!(await pending.value))
    }

    @Test("掃描卡住：refresh 在期限內返回並保留原本的清單")
    func hungScanKeepsList() async {
        let f = makeFixture()
        #expect(await f.backup.backupNow())
        await f.backup.refresh()
        #expect(f.backup.files.count == 1)

        f.faults.set(.cloudScan, .hang)
        defer { f.faults.set(.cloudScan, nil) }
        let started = ContinuousClock.now
        await f.backup.refresh()
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(f.backup.files.count == 1)
    }

    @Test("匯入時讀取卡住：不套用任何設定")
    func hungImportAppliesNothing() async {
        let f = makeFixture()
        #expect(await f.backup.backupNow())
        await f.backup.refresh()
        let file = f.backup.files[0]
        f.settings.focusLastDuration = 999

        f.faults.set(.cloudRead, .hang)
        defer { f.faults.set(.cloudRead, nil) }
        #expect(!(await f.backup.importBackup(file)))
        #expect(f.settings.focusLastDuration == 999)
        guard case .deferred = f.backup.status else {
            Issue.record("status 應為 deferred，實際 \(f.backup.status)")
            return
        }
    }
}

@Suite("備份 I/O worker")
struct BackupIOWorkerTests {
    private func makeWorker(maxQueued: Int = 8) -> BackupIOWorker {
        BackupIOWorker(
            files: CloudBackupFiles(location: .fixed(nil), deviceName: "Mac", deviceID: "x"),
            maxQueued: maxQueued
        )
    }

    @Test("期限內完成回結果；逾時回 timedOut，晚到的結果丟掉")
    func completesOrTimesOut() async {
        let worker = makeWorker()
        guard case .completed(.success(7)) = await worker.run(deadline: .seconds(2), { _ in 7 }) else {
            Issue.record("應完成")
            return
        }
        let slow = await worker.run(deadline: .milliseconds(50)) { _ -> Int in
            Thread.sleep(forTimeInterval: 0.3)
            return 1
        }
        guard case .timedOut = slow else {
            Issue.record("應逾時")
            return
        }
    }

    @Test("前一件卡過期限：新工作直接 busy，不排在後面")
    func stuckWorkerRejects() async throws {
        let worker = makeWorker()
        let release = DispatchSemaphore(value: 0)
        let stuck = Task {
            await worker.run(deadline: .milliseconds(50)) { _ in release.wait() }
        }
        try await Task.sleep(for: .milliseconds(150))
        guard case .busy = await worker.run(deadline: .seconds(1), { _ in 1 }) else {
            Issue.record("應 busy")
            release.signal()
            return
        }
        #expect(!worker.isIdle)
        release.signal()
        _ = await stuck.value
        let deadline = ContinuousClock.now + .seconds(2)
        while !worker.isIdle, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(worker.isIdle)
    }

    @Test("排隊有上限")
    func queueIsBounded() async throws {
        let worker = makeWorker(maxQueued: 2)
        let release = DispatchSemaphore(value: 0)
        let tasks = (0..<2).map { _ in
            Task { await worker.run(deadline: .seconds(5)) { _ in release.wait() } }
        }
        try await Task.sleep(for: .milliseconds(100))
        // 一件在跑、一件在排：再來兩件，至少一件被擋
        let extra = (0..<2).map { _ in Task { await worker.run(deadline: .seconds(5)) { _ in } } }
        try await Task.sleep(for: .milliseconds(100))
        for _ in 0..<4 { release.signal() }
        var busy = 0
        for task in extra {
            if case .busy = await task.value { busy += 1 }
        }
        for task in tasks { _ = await task.value }
        #expect(busy >= 1)
    }
}

@MainActor
@Suite("回應性基線：主迴圈探測", .serialized)
struct MainLoopWatchdogTests {
    /// 同步佔住主執行緒，模擬主執行緒上的阻塞 I/O。
    private func blockMainThread(seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @Test("主執行緒被佔住 → 記到延遲與卡住，恢復後停頓時間量得到")
    func detectsStall() async throws {
        let watchdog = MainLoopWatchdog(
            configuration: .init(
                interval: .milliseconds(50),
                thresholds: .init(lag: .milliseconds(150), hang: .milliseconds(400)),
                summaryInterval: .seconds(3_600),
                operationStallThreshold: .seconds(3_600)
            ),
            metrics: OperationMetrics(log: nil),
            log: nil
        )
        watchdog.start()
        defer { watchdog.stop() }

        try await Task.sleep(for: .milliseconds(200))
        #expect(watchdog.snapshot().lifetime.latency.count > 0)
        #expect(watchdog.snapshot().lifetime.hangCount == 0)

        blockMainThread(seconds: 0.8)
        try await Task.sleep(for: .milliseconds(300))

        let snapshot = watchdog.snapshot()
        #expect(snapshot.lifetime.hangCount >= 1)
        #expect(snapshot.lifetime.lagCount >= 1)
        #expect(snapshot.lifetime.longestStall >= .milliseconds(600))
    }

    @Test("start 重複呼叫無副作用；stop 後不再取樣")
    func startStop() async throws {
        let watchdog = MainLoopWatchdog(
            configuration: .init(interval: .milliseconds(20)),
            metrics: OperationMetrics(log: nil),
            log: nil
        )
        watchdog.start()
        watchdog.start()
        try await Task.sleep(for: .milliseconds(120))
        watchdog.stop()
        #expect(!watchdog.snapshot().running)
        try await Task.sleep(for: .milliseconds(50))
        let count = watchdog.snapshot().lifetime.latency.count
        try await Task.sleep(for: .milliseconds(120))
        #expect(watchdog.snapshot().lifetime.latency.count == count)
    }
}
