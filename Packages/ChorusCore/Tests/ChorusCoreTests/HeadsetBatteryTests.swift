import Foundation
import Testing
@testable import ChorusCore

@Suite("藍牙 MAC 從 CoreAudio UID 轉出")
struct BluetoothAddressTests {
    @Test(":output／:input 都能轉，大小寫正規化成冒號格式")
    func fromAudioUID() {
        #expect(BluetoothAddress.fromAudioUID("94-16-25-48-CC-A9:output") == "94:16:25:48:CC:A9")
        #expect(BluetoothAddress.fromAudioUID("94-16-25-48-cc-a9:input") == "94:16:25:48:CC:A9")
        #expect(BluetoothAddress.fromAudioUID("BuiltInSpeakerDevice") == nil)
        #expect(BluetoothAddress.fromAudioUID("ChorusAudioDevice_UID") == nil)
        #expect(BluetoothAddress.fromAudioUID("94:16:25:48:CC:A9") == nil)
    }
}

@Suite("system_profiler 藍牙電量報告")
struct BluetoothBatteryReportTests {
    @Test("只解析 device_connected；device_not_connected 的舊電量不收錄")
    func ignoresDisconnected() throws {
        let json = """
        {"SPBluetoothDataType":[{"device_connected":[
          {"憲有的AirPods":{"device_address":"94:16:25:48:CC:A9","device_batteryLevelLeft":"92%","device_batteryLevelRight":"93%"}}
        ],"device_not_connected":[
          {"舊的":{"device_address":"F8:D3:F0:59:73:BD","device_batteryLevelCase":"28%","device_batteryLevelLeft":"100%","device_batteryLevelRight":"100%"}}
        ]}]}
        """.data(using: .utf8)!
        let report = try #require(BluetoothBatteryReport.parse(json))
        #expect(report.keys.sorted() == ["94:16:25:48:CC:A9"])
        #expect(report["94:16:25:48:CC:A9"] == HeadsetBattery(main: nil, left: 92, right: 93, chargingCase: nil))
    }

    @Test("只有 Main；只有 Left/Right；Left/Right 不同時取較低值；缺充電盒；0% 有效")
    func fieldCombinations() throws {
        let json = """
        {"SPBluetoothDataType":[{"device_connected":[
          {"Max":{"device_address":"70:F9:4A:8D:BC:0C","device_batteryLevelMain":"100%"}},
          {"Pods":{"device_address":"aa:bb:cc:dd:ee:ff","device_batteryLevelLeft":"0%","device_batteryLevelRight":"40%"}},
          {"單邊":{"device_address":"11:22:33:44:55:66","device_batteryLevelLeft":"55%"}}
        ]}]}
        """.data(using: .utf8)!
        let report = try #require(BluetoothBatteryReport.parse(json))
        #expect(report["70:F9:4A:8D:BC:0C"]?.displayPercent == 100)
        #expect(report["70:F9:4A:8D:BC:0C"]?.main == 100)
        #expect(report["AA:BB:CC:DD:EE:FF"]?.displayPercent == 0)
        #expect(report["11:22:33:44:55:66"]?.displayPercent == 55)
        #expect(report["11:22:33:44:55:66"]?.chargingCase == nil)
    }

    @Test("解析失敗、超出 0–100 → 該欄 nil；四欄都 nil → 不收錄")
    func invalidPercents() throws {
        let json = """
        {"SPBluetoothDataType":[{"device_connected":[
          {"壞的":{"device_address":"01:02:03:04:05:06","device_batteryLevelMain":"abc","device_batteryLevelLeft":"120%","device_batteryLevelRight":"","device_batteryLevelCase":"101%"}},
          {"空的":{"device_address":"07:08:09:0A:0B:0C"}}
        ]}]}
        """.data(using: .utf8)!
        let report = try #require(BluetoothBatteryReport.parse(json))
        #expect(report["01:02:03:04:05:06"] == nil)
        #expect(report["07:08:09:0A:0B:0C"] == nil)
        #expect(report.isEmpty)
    }
}

@Suite("HeadsetBattery 顯示與分級")
struct HeadsetBatteryValueTests {
    @Test("顯示百分比：main 優先，否則左右取較低；充電盒不算")
    func displayPercent() {
        #expect(HeadsetBattery(main: 80, left: 10, right: 20, chargingCase: 5).displayPercent == 80)
        #expect(HeadsetBattery(main: nil, left: 93, right: 91, chargingCase: 28).displayPercent == 91)
        #expect(HeadsetBattery(main: nil, left: 50, right: nil, chargingCase: 90).displayPercent == 50)
        #expect(HeadsetBattery(main: nil, left: nil, right: nil, chargingCase: 90).displayPercent == nil)
    }

    @Test("分級邊界：20 → low、21 → normal、10 → critical")
    func levels() {
        #expect(HeadsetBattery(main: 21, left: nil, right: nil, chargingCase: nil).level == .normal)
        #expect(HeadsetBattery(main: 20, left: nil, right: nil, chargingCase: nil).level == .low)
        #expect(HeadsetBattery(main: 10, left: nil, right: nil, chargingCase: nil).level == .critical)
        #expect(HeadsetBattery(main: 9, left: nil, right: nil, chargingCase: nil).level == .critical)
        #expect(HeadsetBattery(main: nil, left: nil, right: nil, chargingCase: 5).level == nil)
    }
}

@Suite("HeadsetBatteryPolicy 輪詢判斷")
struct HeadsetBatteryPolicyTests {
    @Test("無目標不輪詢；頂端關閉＋選單關閉不輪詢")
    func shouldPoll() {
        #expect(!HeadsetBatteryPolicy.shouldPoll(hasTarget: false, menuBarEnabled: true, menuOpen: false))
        #expect(!HeadsetBatteryPolicy.shouldPoll(hasTarget: true, menuBarEnabled: false, menuOpen: false))
        #expect(HeadsetBatteryPolicy.shouldPoll(hasTarget: true, menuBarEnabled: true, menuOpen: false))
        #expect(HeadsetBatteryPolicy.shouldPoll(hasTarget: true, menuBarEnabled: false, menuOpen: true))
    }

    @Test("超過 180 秒視為過期；打開選單時超過 30 秒要重抓")
    func freshness() {
        #expect(HeadsetBatteryPolicy.isStale(age: .seconds(179)) == false)
        #expect(HeadsetBatteryPolicy.isStale(age: .seconds(180)) == true)
        #expect(HeadsetBatteryPolicy.shouldRefreshOnMenuOpen(age: .seconds(29)) == false)
        #expect(HeadsetBatteryPolicy.shouldRefreshOnMenuOpen(age: .seconds(30)) == true)
        #expect(HeadsetBatteryPolicy.shouldRefreshOnMenuOpen(age: nil) == true)
    }

    @Test("剛連上補抓時間點")
    func connectRetries() {
        #expect(HeadsetBatteryPolicy.connectRetries == [.seconds(3), .seconds(10)])
        #expect(HeadsetBatteryPolicy.pollInterval == .seconds(60))
    }
}
