import Foundation
import Testing
@testable import ChorusCore

@Suite("RemoteDeviceDirectory")
struct RemoteDeviceDirectoryTests {
    @Test("storageKey 可以往返，裝置識別碼含分隔符也不會拆錯")
    func storageKeyRoundTrip() {
        let id = RemoteEndpointID(peerID: "peer-1", kind: .display, deviceID: "UUID-abc")
        #expect(RemoteEndpointID(storageKey: id.storageKey) == id)

        // audio device UID 是廠商給的字串，含 `|` 不是不可能。裝置識別碼放在
        // 最後一段、用 maxSplits 切，就是為了這種情況。
        let weird = RemoteEndpointID(peerID: "peer-1", kind: .audioOutput, deviceID: "a|b|c")
        #expect(RemoteEndpointID(storageKey: weird.storageKey) == weird)
    }

    @Test("格式不符的鍵解不出來，而不是解成一個錯的端點")
    func storageKeyRejectsMalformed() {
        #expect(RemoteEndpointID(storageKey: "just-one-part") == nil)
        #expect(RemoteEndpointID(storageKey: "peer|display") == nil)
        #expect(RemoteEndpointID(storageKey: "|display|uuid") == nil)
    }

    /// 線上格式是裸字串（`"display"`），不是 `{"rawValue":"display"}`——
    /// stdlib 對 `RawRepresentable` 的 Codable 條件式實作會接管合成版本。
    /// 這個測試連同那件事一起釘住：換成 enum 或自訂 CodingKeys 都會弄壞它。
    @Test("未知的端點類型與能力解得開，不會讓整包訊息失敗")
    func unknownKindsDecode() throws {
        // 未來版本多一種端點（例如檯燈）時，舊版必須還能解開整份目錄、
        // 只是不認得那一筆。enum 會讓整則 JSON 解碼失敗。
        let json = """
        {"peerID":"p","sessionID":"\(UUID().uuidString)","version":1,"endpoints":[
          {"deviceID":"lamp-1","kind":"lamp","name":"檯燈",
           "capabilities":["colorTemperature"],"values":{},"isDefaultOutput":false}
        ]}
        """
        let directory = try JSONDecoder().decode(DeviceDirectory.self, from: Data(json.utf8))
        #expect(directory.endpoints.count == 1)
        #expect(directory.endpoints[0].kind == RemoteEndpointKind(rawValue: "lamp"))
        #expect(!directory.endpoints[0].supports(.brightness))
    }

    @Test("目錄可以完整往返編解碼")
    func directoryRoundTrip() throws {
        let directory = DeviceDirectory(
            peerID: "p",
            sessionID: UUID(),
            version: 7,
            endpoints: [
                RemoteEndpoint(
                    deviceID: "disp-1",
                    kind: .display,
                    name: "Studio Display",
                    capabilities: [.brightness, .brightnessOffset],
                    values: ["brightness": 0.6, "brightnessOffset": -0.1],
                    discriminator: "abc123"
                ),
                RemoteEndpoint(
                    deviceID: "aud-1",
                    kind: .audioOutput,
                    name: "Studio Display 喇叭",
                    capabilities: [.volume, .mute],
                    linkedDisplayUUID: "disp-1",
                    values: ["volume": 0.4, "mute": 0],
                    isDefaultOutput: true
                ),
            ]
        )
        let data = try JSONEncoder().encode(directory)
        let decoded = try JSONDecoder().decode(DeviceDirectory.self, from: data)
        #expect(decoded == directory)
        #expect(decoded.endpoint(kind: .audioOutput, deviceID: "aud-1")?.value(.volume) == 0.4)
        #expect(decoded.endpoint(kind: .display, deviceID: "aud-1") == nil)
    }

    @Test("指令結果的未知 outcome 解得開")
    func unknownOutcomeDecodes() throws {
        let id = UUID()
        let json = """
        {"id":"\(id.uuidString)","outcome":"throttled"}
        """
        let result = try JSONDecoder().decode(EndpointCommandResult.self, from: Data(json.utf8))
        #expect(result.outcome != .applied)
        #expect(result.outcome != .unavailable)
        #expect(result.value == nil)
    }
}

@Suite("ControlGrouping")
struct ControlGroupingTests {
    @Test("分類：內建歸設備、外接歸螢幕")
    func displayGrouping() {
        #expect(ControlGrouping.group(isBuiltinDisplay: true) == .device)
        #expect(ControlGrouping.group(isBuiltinDisplay: false) == .screen)
        #expect(ControlGrouping.group(isScreenAudioEndpoint: true) == .screen)
        #expect(ControlGrouping.group(isScreenAudioEndpoint: false) == .device)
    }

    @Test("順序固定：設備 → 螢幕 → 遠端")
    func orderIsFixed() {
        #expect(DeviceControlGroup.displayOrder == [.device, .screen, .remote])
    }

    @Test("沒撞名就不加區別後綴")
    func noSuffixWhenUnique() {
        let suffixes = ControlGrouping.disambiguationSuffixes(
            names: ["Studio Display", "LG UltraFine"],
            discriminators: ["aaa", "bbb"]
        )
        #expect(suffixes == [nil, nil])
    }

    @Test("撞名的每一個都加後綴")
    func suffixOnlyForDuplicates() {
        let suffixes = ControlGrouping.disambiguationSuffixes(
            names: ["Studio Display", "Studio Display", "LG UltraFine"],
            discriminators: ["aaa", "bbb", "ccc"]
        )
        // 只加在撞名的那兩個上——沒撞名卻掛一串序號只是雜訊
        #expect(suffixes == ["aaa", "bbb", nil])
    }

    @Test("短識別碼取前 6 碼")
    func shortIdentifier() {
        #expect(ControlGrouping.shortIdentifier("0123456789abcdef") == "012345")
        // 比 6 碼短的原樣回傳，不補字
        #expect(ControlGrouping.shortIdentifier("abc") == "abc")
    }
}
