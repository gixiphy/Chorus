import ChorusCore
import Foundation
import Testing
@testable import Chorus

/// 設定備份（B8）。走真的檔案程式碼，只是把根目錄指到暫存區——
/// **測試不該把東西寫進使用者的 iCloud Drive**。
@MainActor
@Suite("設定備份")
struct CloudBackupTests {
    private struct Fixture {
        let backup: CloudBackup
        let settings: SettingsStore
        let scenes: SceneStore
        let root: URL
        let defaults: UserDefaults
        let deviceID: String
    }

    private func makeFixture(
        root: URL? = nil,
        deviceName: String = "測試 Mac",
        deviceID: String = "device-A"
    ) -> Fixture {
        let directory = root ?? FileManager.default.temporaryDirectory
            .appending(path: "chorus-backup-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: "cloud-backup-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        let scenes = SceneStore(defaults: defaults)
        let backup = CloudBackup(
            files: CloudBackupFiles(location: .fixed(directory), deviceName: deviceName, deviceID: deviceID),
            settings: settings,
            scenes: scenes
        )
        return Fixture(backup: backup, settings: settings, scenes: scenes,
                       root: directory, defaults: defaults, deviceID: deviceID)
    }

    private func deviceFile(_ f: Fixture, named: String = "測試 Mac") -> URL {
        f.root.appending(path: "devices/\(named).json")
    }

    // MARK: - 備份

    @Test("備份寫出一份人看得懂的 JSON，內容是目前的設定")
    func backupWritesSnapshot() async throws {
        let f = makeFixture()
        f.settings.focusLastDuration = 2_700
        f.scenes.save(ControlScene(name: "工作", requests: []))

        #expect(await f.backup.backupNow())
        let data = try Data(contentsOf: deviceFile(f))
        let decoded = try BackupCodec.decode(DeviceBackup.self, from: data)
        #expect(decoded.focusLastDuration == 2_700)
        #expect(decoded.scenes.map(\.name) == ["工作"])
        #expect(decoded.deviceID == "device-A")
    }

    @Test("內容沒變就不重寫——每寫一次都會觸發一輪 iCloud 同步")
    func tickSkipsUnchangedContent() async throws {
        let f = makeFixture()
        f.settings.cloudBackupEnabled = true
        await f.backup.tick()
        let first = try FileManager.default.attributesOfItem(
            atPath: deviceFile(f).path)[.modificationDate] as? Date

        await f.backup.tick()
        let second = try FileManager.default.attributesOfItem(
            atPath: deviceFile(f).path)[.modificationDate] as? Date
        #expect(first == second)

        // 真的變了才寫
        f.settings.focusLastDuration = 60
        await f.backup.tick()
        let third = try FileManager.default.attributesOfItem(
            atPath: deviceFile(f).path)[.modificationDate] as? Date
        #expect(third != second)
    }

    @Test("開關關著時自動備份不動作（預設就是關的）")
    func tickDoesNothingWhenDisabled() async {
        let f = makeFixture()
        #expect(!f.settings.cloudBackupEnabled)
        await f.backup.tick()
        #expect(!FileManager.default.fileExists(atPath: deviceFile(f).path))
    }

    @Test("iCloud Drive 沒開：全部 no-op，狀態誠實說原因")
    func unavailableRootIsHonest() async {
        let f = makeFixture(root: nil)
        let unavailable = CloudBackup(
            files: CloudBackupFiles(location: .fixed(nil), deviceName: "Mac", deviceID: "x"),
            settings: f.settings, scenes: f.scenes
        )
        #expect(!unavailable.isAvailable)
        #expect(!(await unavailable.backupNow()))
        #expect(unavailable.status != .idle)
        #expect(unavailable.files.isEmpty)
    }

    @Test("結束 App 時不碰 iCloud Drive；變更留在本機，下次啟動第一拍補上")
    func shutdownDoesNotWrite() async {
        let f = makeFixture()
        f.settings.cloudBackupEnabled = true
        f.backup.shutdown()
        #expect(!FileManager.default.fileExists(atPath: deviceFile(f).path))

        // 「下次啟動」：同一份 defaults、新的 CloudBackup
        let relaunched = CloudBackup(
            files: CloudBackupFiles(location: .fixed(f.root), deviceName: "測試 Mac", deviceID: f.deviceID),
            settings: f.settings, scenes: f.scenes
        )
        await relaunched.tick()
        #expect(FileManager.default.fileExists(atPath: deviceFile(f).path))
    }

    // MARK: - 檔名

    @Test("檔名用機器名——一排 UUID 檔名等於白放")
    func fileNameUsesDeviceName() async {
        let f = makeFixture(deviceName: "MacBook Pro")
        #expect(await f.backup.backupNow())
        #expect(FileManager.default.fileExists(
            atPath: f.root.appending(path: "devices/MacBook Pro.json").path))
    }

    @Test("檔名裡的斜線與冒號換掉（冒號在 Finder 會顯示成斜線）")
    func fileNameIsSanitized() async {
        let f = makeFixture(deviceName: "憲有/的:Mac")
        #expect(await f.backup.backupNow())
        #expect(FileManager.default.fileExists(
            atPath: f.root.appending(path: "devices/憲有-的-Mac.json").path))
    }

    @Test("兩台同名時第二台帶 id 後綴——判斷依據是檔案裡的 deviceID")
    func collidingNamesGetSuffix() async {
        let first = makeFixture(deviceName: "MacBook Pro", deviceID: "aaaaaaaa-1111")
        #expect(await first.backup.backupNow())

        let second = makeFixture(root: first.root, deviceName: "MacBook Pro",
                                 deviceID: "bbbbbbbb-2222")
        #expect(await second.backup.backupNow())
        #expect(FileManager.default.fileExists(
            atPath: first.root.appending(path: "devices/MacBook Pro-bbbbbbbb.json").path))
    }

    // MARK: - 清單

    @Test("列出每一台的備份，並標出哪一份是自己的")
    func scanListsFiles() async {
        let mine = makeFixture(deviceName: "我的 Mac", deviceID: "mine")
        #expect(await mine.backup.backupNow())
        let other = makeFixture(root: mine.root, deviceName: "另一台", deviceID: "other")
        #expect(await other.backup.backupNow())

        await mine.backup.refresh()
        let names = mine.backup.files.map(\.deviceName).sorted()
        #expect(names == ["另一台", "我的 Mac"])
        #expect(mine.backup.files.first { $0.deviceName == "我的 Mac" }?.isSelf == true)
        #expect(mine.backup.files.first { $0.deviceName == "另一台" }?.isSelf == false)
    }

    @Test("解不開的檔案略過，不讓整份清單消失")
    func scanSkipsUnreadableFiles() async throws {
        let f = makeFixture()
        #expect(await f.backup.backupNow())
        try "使用者自己丟進去的東西".write(
            to: f.root.appending(path: "devices/隨手筆記.json"), atomically: true, encoding: .utf8)

        await f.backup.refresh()
        #expect(f.backup.files.count == 1)
    }

    // MARK: - 匯入

    /// 一台「別的機器」，設定與本機處處不同。
    private func makeOther(root: URL) async -> Fixture {
        let other = makeFixture(root: root, deviceName: "另一台", deviceID: "other")
        other.scenes.save(ControlScene(name: "來自另一台", requests: []))
        other.settings.focusLastDuration = 2_700          // 可攜
        other.settings.mediaKeyCaptureEnabled = true      // 可攜
        other.settings.forceSoftwareDimming = ["別台的螢幕"] // 綁機
        other.settings.audioTapsEnabled = true            // 權限
        other.settings.excludedDevices = ["別台的裝置"]     // 綁機
        #expect(await other.backup.backupNow())
        return other
    }

    @Test("匯入別台：可攜的跟著走，綁機與權限的留本機")
    func importFromAnotherMachine() async {
        let f = makeFixture(deviceName: "我的 Mac", deviceID: "mine")
        f.settings.forceSoftwareDimming = ["我的螢幕"]
        f.settings.excludedDevices = ["我的裝置"]
        #expect(!f.settings.audioTapsEnabled)
        _ = await makeOther(root: f.root)

        await f.backup.refresh()
        let file = f.backup.files.first { !$0.isSelf }
        #expect(file != nil)
        #expect(await f.backup.importBackup(file!))

        #expect(f.scenes.scenes.map(\.name) == ["來自另一台"])
        #expect(f.settings.focusLastDuration == 2_700)
        #expect(f.settings.mediaKeyCaptureEnabled)
        // 綁機與權限：原封不動
        #expect(f.settings.forceSoftwareDimming == ["我的螢幕"])
        #expect(f.settings.excludedDevices == ["我的裝置"])
        #expect(!f.settings.audioTapsEnabled)
    }

    @Test("匯入同一台（重灌後）：全套，綁機的鍵正是最想要回來的東西")
    func importFromSameMachineTakesEverything() async {
        let original = makeFixture(deviceName: "我的 Mac", deviceID: "mine")
        original.settings.forceSoftwareDimming = ["這台的螢幕"]
        original.settings.audioTapsEnabled = true
        original.scenes.save(ControlScene(name: "工作", requests: []))
        #expect(await original.backup.backupNow())

        // 「重灌」：同一個 deviceID、乾淨的 defaults
        let reinstalled = makeFixture(root: original.root, deviceName: "我的 Mac", deviceID: "mine")
        await reinstalled.backup.refresh()
        let file = reinstalled.backup.files.first { $0.isSelf }
        #expect(file != nil)
        #expect(await reinstalled.backup.importBackup(file!))

        #expect(reinstalled.settings.forceSoftwareDimming == ["這台的螢幕"])
        #expect(reinstalled.settings.audioTapsEnabled)
        #expect(reinstalled.scenes.scenes.map(\.name) == ["工作"])
    }

    @Test("匯入前先留一份退路——這個動作會蓋掉目前的設定")
    func importLeavesEscapeHatch() async {
        let f = makeFixture(deviceName: "我的 Mac", deviceID: "mine")
        f.settings.focusLastDuration = 111
        _ = await makeOther(root: f.root)

        await f.backup.refresh()
        #expect(await f.backup.importBackup(f.backup.files.first { !$0.isSelf }!))

        let escape = f.root.appending(path: "devices/我的 Mac-before-import.json")
        #expect(FileManager.default.fileExists(atPath: escape.path))
        let saved = try? BackupCodec.decode(
            DeviceBackup.self, from: Data(contentsOf: escape))
        #expect(saved?.focusLastDuration == 111)
    }

    @Test("匯入之後下一拍會把新設定寫出去（不會因為「內容沒變」跳過）")
    func importMarksContentDirty() async throws {
        let f = makeFixture(deviceName: "我的 Mac", deviceID: "mine")
        f.settings.cloudBackupEnabled = true
        await f.backup.tick()
        _ = await makeOther(root: f.root)

        await f.backup.refresh()
        #expect(await f.backup.importBackup(f.backup.files.first { !$0.isSelf }!))
        await f.backup.tick()

        let written = try BackupCodec.decode(
            DeviceBackup.self, from: Data(contentsOf: deviceFile(f, named: "我的 Mac")))
        #expect(written.focusLastDuration == 2_700)
    }
}
