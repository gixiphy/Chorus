import ChorusCore
import Foundation
import Testing
@testable import Chorus

/// Batch F：記憶體壓力降級。系統事件無法在測試裡觸發，直接送等級進去。
@MainActor
@Suite("記憶體壓力降級", .serialized)
struct MemoryPressureTests {
    @Test("critical 立刻降級；恢復正常後等恢復期才解除")
    func escalationAndRecovery() async throws {
        let monitor = MemoryPressureMonitor(recovery: .milliseconds(200), tickInterval: .milliseconds(50), log: nil)
        #expect(!monitor.blocksHeavyWork)
        monitor.report(.critical)
        #expect(monitor.blocksHeavyWork)

        monitor.report(.normal)
        #expect(monitor.blocksHeavyWork)
        try await Task.sleep(for: .milliseconds(600))
        #expect(!monitor.blocksHeavyWork)
        #expect(monitor.level == .normal)
    }

    @Test("warning 只記錄，不擋任何工作")
    func warningDoesNotBlock() {
        let monitor = MemoryPressureMonitor(log: nil)
        monitor.report(.warning)
        #expect(monitor.level == .warning)
        #expect(!monitor.blocksHeavyWork)
    }

    @Test("critical 時自動備份整拍跳過，手動備份照常")
    func backupDefersOnlyAutomaticTicks() async {
        let root = FileManager.default.temporaryDirectory.appending(path: "chorus-pressure-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "chorus-pressure-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let scenes = SceneStore(defaults: defaults)
        let monitor = MemoryPressureMonitor(log: nil)
        let backup = CloudBackup(
            files: CloudBackupFiles(location: .fixed(root), deviceName: "壓力測試", deviceID: "pressure"),
            settings: settings,
            scenes: scenes,
            pressure: monitor
        )
        let file = root.appending(path: "devices/壓力測試.json")
        settings.cloudBackupEnabled = true
        monitor.report(.critical)

        await backup.tick()
        #expect(!FileManager.default.fileExists(atPath: file.path))

        #expect(await backup.backupNow())
        #expect(FileManager.default.fileExists(atPath: file.path))
    }
}
