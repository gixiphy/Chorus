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

/// 備份檔案層接上故障與計量之後：卡住的時間真的落在呼叫端（目前是主執行緒）。
@MainActor
@Suite("回應性基線：備份 I/O")
struct CloudBackupFaultTests {
    /// CloudBackup 以 unowned 參照 SceneStore——stores 要由呼叫端留著。
    private struct Fixture {
        let backup: CloudBackup
        let settings: SettingsStore
        let scenes: SceneStore
    }

    private func makeFixture(faults: FaultRegistry, metrics: OperationMetrics) -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "chorus-backup-fault-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "cloud-backup-fault-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let scenes = SceneStore(defaults: defaults)
        let backup = CloudBackup(
            files: CloudBackupFiles(
                root: directory, deviceName: "測試 Mac", deviceID: "device-A",
                faults: faults, metrics: metrics
            ),
            settings: settings,
            scenes: scenes
        )
        return Fixture(backup: backup, settings: settings, scenes: scenes)
    }

    @Test("寫入故障 → 備份回報失敗，計量記一次 cloud.write 失敗")
    func writeFailure() {
        let faults = FaultRegistry()
        let metrics = OperationMetrics(log: nil)
        let fixture = makeFixture(faults: faults, metrics: metrics)
        let backup = fixture.backup
        faults.set(.cloudWrite, .fail)

        #expect(!backup.backupNow())
        guard case .failed = backup.status else {
            Issue.record("status 應為 failed，實際 \(backup.status)")
            return
        }
        #expect(metrics.snapshot().operations["cloud.write"]?.outcomes[.failure] == 1)
    }

    @Test("寫入延遲 → backupNow 在主執行緒上同步等完（現況基線）")
    func writeDelayBlocksCaller() {
        let faults = FaultRegistry()
        let metrics = OperationMetrics(log: nil)
        let fixture = makeFixture(faults: faults, metrics: metrics)
        let backup = fixture.backup
        faults.set(.cloudWrite, .delay(.milliseconds(300)))

        let started = ContinuousClock.now
        #expect(backup.backupNow())
        #expect(ContinuousClock.now - started >= .milliseconds(290))
        #expect((metrics.snapshot().operations["cloud.write"]?.latency.maxMillis ?? 0) >= 290)
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
