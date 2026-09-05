import Foundation
import Testing
@testable import ChorusCore

@Suite("設定備份（B8）")
struct DeviceBackupTests {
    /// 每個欄位都給一個「非預設」的值，兩份之間彼此不同——合併之後才分辨得出
    /// 某個欄位到底來自哪一邊。
    private func sample(_ tag: String, port: UInt16, flag: Bool) -> DeviceBackup {
        DeviceBackup(
            savedAt: Date(timeIntervalSince1970: flag ? 100 : 200),
            deviceName: "Mac-\(tag)",
            deviceID: "id-\(tag)",
            scenes: [ControlScene(name: "場景-\(tag)", requests: [])],
            deviceEQ: ["uid-\(tag)": EQSettings()],
            deviceBalance: ["uid-\(tag)": flag ? 0.3 : 0.7],
            deviceEffects: ["uid-\(tag)": []],
            appAudio: AppAudioSettings(entries: [
                "com.apple.Music": AppAudioSetting(
                    gain: flag ? 0.5 : 1.5, muted: flag, outputDeviceUID: "route-\(tag)"
                ),
            ]),
            excludedApps: ["app-\(tag)"],
            excludedDevices: ["dev-\(tag)"],
            softwareVolumeDevices: ["sw-\(tag)"],
            outputPriority: ["pri-\(tag)"],
            hiddenAudioDevices: ["hid-\(tag)"],
            audioBridgeDisabled: ["br-\(tag)"],
            virtualTargetUID: "vt-\(tag)",
            effectQuarantine: ["q-\(tag)"],
            audioTapsEnabled: flag,
            forceSoftwareDimming: ["fsd-\(tag)"],
            subZeroDimming: ["sz-\(tag)"],
            disableDDCRead: ["ddc-\(tag)"],
            autoBrightnessEnabled: flag,
            ambientCurve: AmbientCurve(minBrightness: flag ? 0.1 : 0.2, maxLux: flag ? 400 : 800),
            ambientDisplayOffsets: ["disp-\(tag)": flag ? 0.1 : 0.2],
            ambientDeviceOffset: flag ? 0.05 : 0.15,
            ambientExcludedDisplays: ["ex-\(tag)"],
            ambientScheduleEnabled: flag,
            ambientSchedule: AmbientSchedule(dayLux: flag ? 300 : 600, nightLux: flag ? 20 : 60, dawnMinute: flag ? 400 : 420, duskMinute: flag ? 1080 : 1140),
            keepAwakePreventsSystemSleep: flag,
            keepAwakeDisplayUUID: "ka-disp-\(tag)",
            keepAwakeAppBundleID: "ka-app-\(tag)",
            mediaKeyCaptureEnabled: flag,
            syncBrightnessEnabled: flag,
            syncVolumeEnabled: flag,
            advisorEngineID: "engine-\(tag)",
            advisorModelIDs: ["e": "m-\(tag)"],
            advisorDisabledEngines: ["dis-\(tag)"],
            advisorCustomPaths: ["e": "/path/\(tag)"],
            automationServerEnabled: flag,
            automationServerPort: port,
            focusLastDuration: flag ? 900 : 2_700,
            focusNotifyOnEnd: flag,
            cloudBackupEnabled: flag
        )
    }

    private func fieldNames(_ backup: DeviceBackup) -> [String] {
        Mirror(reflecting: backup).children.compactMap(\.label)
    }

    // MARK: - 登錄表

    @Test("每個備份欄位都要登錄可攜性——新增欄位忘了分類就紅")
    func everyFieldIsClassified() {
        let classified = BackupPortability.portable
            .union(BackupPortability.machineBound)
            .union(BackupPortability.identity)
        let unclassified = Set(fieldNames(sample("A", port: 1, flag: true))).subtracting(classified)
        #expect(unclassified.isEmpty, "未登錄的欄位：\(unclassified.sorted())")
    }

    @Test("同一個欄位不能同時是可攜與綁機")
    func classificationsAreDisjoint() {
        #expect(BackupPortability.portable.isDisjoint(with: BackupPortability.machineBound))
        #expect(BackupPortability.portable.isDisjoint(with: BackupPortability.identity))
        #expect(BackupPortability.machineBound.isDisjoint(with: BackupPortability.identity))
    }

    @Test("登錄表裡沒有不存在的欄位（改名時要跟著改）")
    func noPhantomFields() {
        let actual = Set(fieldNames(sample("A", port: 1, flag: true)))
        let listed = BackupPortability.portable
            .union(BackupPortability.machineBound)
            .union(BackupPortability.identity)
        #expect(listed.subtracting(actual).isEmpty, "登錄表裡多出來的：\(listed.subtracting(actual).sorted())")
    }

    // MARK: - 跨機匯入

    @Test("跨機匯入逐欄位符合登錄表——漏寫一行合併就會被抓到")
    func portableMergeMatchesRegistry() {
        let local = sample("local", port: 1, flag: true)
        let remote = sample("remote", port: 2, flag: false)
        let merged = remote.portableMerged(onto: local)

        let mergedFields = Dictionary(uniqueKeysWithValues:
            Mirror(reflecting: merged).children.map { ($0.label ?? "", "\($0.value)") })
        let localFields = Dictionary(uniqueKeysWithValues:
            Mirror(reflecting: local).children.map { ($0.label ?? "", "\($0.value)") })
        let remoteFields = Dictionary(uniqueKeysWithValues:
            Mirror(reflecting: remote).children.map { ($0.label ?? "", "\($0.value)") })

        for field in BackupPortability.machineBound.union(BackupPortability.identity) {
            #expect(mergedFields[field] == localFields[field], "\(field) 應保留本機的值")
        }
        for field in BackupPortability.portable where field != "appAudio" {
            #expect(mergedFields[field] == remoteFields[field], "\(field) 應採用備份的值")
        }
    }

    @Test("per-app：EQ／增益／靜音跟著走，路由清掉（跨機是空殼）")
    func appAudioKeepsSettingsButDropsRoute() {
        let local = sample("local", port: 1, flag: true)
        let remote = sample("remote", port: 2, flag: false)
        let merged = remote.portableMerged(onto: local)

        let entry = merged.appAudio["com.apple.Music"]
        #expect(entry.gain == 1.5)          // 來自 remote
        #expect(entry.muted == false)       // 來自 remote
        #expect(entry.outputDeviceUID == nil) // 路由清掉——那個裝置不在這台上
    }

    @Test("同機匯入是全套——綁機的鍵正是重灌後最想要回來的東西")
    func sameMachineImportTakesEverything() {
        // 同機匯入不走 portableMerged，直接套用整份；這條守的是那個差別
        // 確實存在：合併後的結果與原份**不同**
        let local = sample("local", port: 1, flag: true)
        let remote = sample("remote", port: 2, flag: false)
        #expect(remote.portableMerged(onto: local) != remote)
    }

    // MARK: - 編解碼

    @Test("JSON 往返")
    func roundTrip() throws {
        let original = sample("A", port: 55_780, flag: true)
        let data = try BackupCodec.encode(original)
        #expect(try BackupCodec.decode(DeviceBackup.self, from: data) == original)
    }

    @Test("檔案是人看得懂的 JSON——它就躺在使用者的 iCloud Drive 裡")
    func encodedFormIsReadable() throws {
        let text = String(decoding: try BackupCodec.encode(sample("A", port: 1, flag: true)), as: UTF8.self)
        #expect(text.contains("\n"))              // pretty printed
        #expect(text.contains("\"deviceName\""))
        #expect(text.contains("1970-01-01"))      // ISO 8601 而不是 unix 秒數
    }

    @Test("比這個 build 新的版本不硬套——半套的設定比不套更難查")
    func rejectsNewerVersion() throws {
        var future = sample("A", port: 1, flag: true)
        future.version = DeviceBackup.currentVersion + 1
        let data = try BackupCodec.encode(future)
        #expect(throws: BackupCodec.Failure.unsupportedVersion(DeviceBackup.currentVersion + 1)) {
            try BackupCodec.decode(DeviceBackup.self, from: data)
        }
    }

    @Test("舊檔缺欄位仍解得開——那是「換一台新機器、版本不同」的常態")
    func decodesFileMissingFields() throws {
        let json = """
        {"version":1,"savedAt":"2026-09-02T00:00:00Z","deviceName":"舊 Mac","deviceID":"old"}
        """
        let decoded = try BackupCodec.decode(DeviceBackup.self, from: Data(json.utf8))
        #expect(decoded.deviceName == "舊 Mac")
        #expect(decoded.scenes.isEmpty)
        #expect(decoded.automationServerPort == 55_780)
        #expect(decoded.syncBrightnessEnabled)      // 預設 true，不是 false
        #expect(decoded.focusLastDuration == 1_500)
    }

    // MARK: - 內容比對

    @Test("內容比對忽略時間戳——否則每一拍都判成「變了」而重寫檔")
    func contentComparisonIgnoresTimestamp() {
        var a = sample("A", port: 1, flag: true)
        var b = a
        b.savedAt = .now
        #expect(a.hasSameContent(as: b))

        b.focusLastDuration = 60
        #expect(!a.hasSameContent(as: b))

        // 機器改名要寫一次：檔名跟著它走
        a.deviceName = "改名後"
        #expect(!a.hasSameContent(as: b))
    }

    @Test("集合存成排序過的陣列——Set 的編碼順序不保證，會被誤判成內容變了")
    func collectionsAreSorted() {
        let backup = DeviceBackup(
            savedAt: .now, deviceName: "Mac", deviceID: "id",
            excludedApps: ["c", "a", "b"]
        )
        #expect(backup.excludedApps == ["a", "b", "c"])
    }
}
