import Foundation
import Testing
@testable import ChorusCore

@Suite("Envelope coding")
struct EnvelopeTests {
    @Test("All message cases round-trip")
    func roundTrip() throws {
        let hlc = HLCTimestamp(wallMicros: 1, counter: 0, peerID: "A")
        let messages: [SyncMessage] = [
            .hello(Hello(peerID: "A", deviceName: "Mac A", protocolVersion: 1)),
            .hello(Hello(peerID: "A", deviceName: "Mac A", protocolVersion: 1, deviceKind: "mac", capabilities: ["als", "display"])),
            .stateUpdate(StateUpdate(originID: "A", seq: 1, hlc: hlc, key: .brightness(displayUUID: nil), value: 0.5)),
            .command(Command(key: .volume(deviceUID: "uid-1"), value: 0.3)),
            .command(Command(key: .input(displayUUID: "uuid-1"), value: 17)),
            .command(Command(key: .contrast(displayUUID: "uuid-1"), value: 0.75)),
            .fullState(FullState(entries: [.init(key: .mute(deviceUID: nil), value: 1, hlc: hlc)])),
            .ping(7),
            .pong(7),
            .ambientReport(AmbientReport(originID: "A", hlc: hlc, lux: 420.5)),
            .setDeviceOffset(DeviceOffsetCommand(offset: -0.2)),
            .stateQuery(StateQuery()),
            .stateReport(StateReport(entries: [
                .init(key: .brightness(displayUUID: nil), value: 0.42),
                .init(key: .volume(deviceUID: nil), value: 0.18),
                .init(key: .mute(deviceUID: nil), value: 0),
            ])),
        ]
        for message in messages {
            let data = try EnvelopeCoding.encode(Envelope(msg: message))
            guard case let .success(decoded) = EnvelopeCoding.decode(data) else {
                Issue.record("decode failed for \(message)")
                continue
            }
            #expect(decoded.v == ChorusProtocol.version)
        }
    }

    @Test("Newer protocol version with unknown message is reported as unsupported")
    func unsupportedVersion() {
        let json = #"{"v": 999, "msg": {"teleport": {}}}"#
        guard case let .failure(error) = EnvelopeCoding.decode(Data(json.utf8)) else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .unsupportedVersion(999))
    }

    @Test("Garbage data is malformed, not a crash")
    func malformed() {
        guard case let .failure(error) = EnvelopeCoding.decode(Data("not json at all".utf8)) else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .malformed)
    }

    @Test("Current version with unknown message is malformed (drop, keep connection)")
    func currentVersionUnknownMessage() {
        let json = #"{"v": 1, "msg": {"teleport": {}}}"#
        guard case let .failure(error) = EnvelopeCoding.decode(Data(json.utf8)) else {
            Issue.record("expected failure")
            return
        }
        #expect(error == .malformed)
    }

    /// 新增的 command 專用鍵（input/contrast）：確認線上格式與可解性。
    /// 舊版 peer 解不開這些 key 時走 malformed → 逐則丟棄（上面測試已覆蓋）。
    @Test("Input/contrast command keys encode with associated UUID and raw value")
    func inputContrastWireFormat() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(ControlKey.input(displayUUID: "u"))
        #expect(String(data: data, encoding: .utf8) == #"{"input":{"displayUUID":"u"}}"#)
        let decoded = try JSONDecoder().decode(ControlKey.self, from: data)
        #expect(decoded == .input(displayUUID: "u"))
    }

    /// Golden JSON：鎖定 v1 既有訊息的線上格式。此測試若失敗，代表改動破壞了
    /// 與舊版 peer 的相容性（ControlKey/StateUpdate/FullState 本里程碑凍結）。
    @Test("Golden JSON: v1 stateUpdate/fullState wire format is frozen")
    func goldenWireFormat() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let hlc = HLCTimestamp(wallMicros: 1, counter: 0, peerID: "A")

        let update = Envelope(msg: .stateUpdate(
            StateUpdate(originID: "A", seq: 1, hlc: hlc, key: .brightness(displayUUID: nil), value: 0.5)
        ))
        #expect(
            String(data: try encoder.encode(update), encoding: .utf8) ==
            #"{"msg":{"stateUpdate":{"_0":{"hlc":{"counter":0,"peerID":"A","wallMicros":1},"key":{"brightness":{}},"originID":"A","seq":1,"value":0.5}}},"v":1}"#
        )

        let full = Envelope(msg: .fullState(
            FullState(entries: [.init(key: .mute(deviceUID: nil), value: 1, hlc: hlc)])
        ))
        #expect(
            String(data: try encoder.encode(full), encoding: .utf8) ==
            #"{"msg":{"fullState":{"_0":{"entries":[{"hlc":{"counter":0,"peerID":"A","wallMicros":1},"key":{"mute":{}},"value":1}]}}},"v":1}"#
        )
    }

    @Test("Hello without new optional fields decodes with nils (old peer compat)")
    func helloMissingOptionalFields() {
        let json = #"{"v":1,"msg":{"hello":{"_0":{"deviceName":"Mac B","peerID":"B","protocolVersion":1}}}}"#
        guard case let .success(envelope) = EnvelopeCoding.decode(Data(json.utf8)),
              case let .hello(hello) = envelope.msg
        else {
            Issue.record("expected hello")
            return
        }
        #expect(hello.deviceKind == nil)
        #expect(hello.capabilities == nil)
    }

    @Test("Hello with unknown extra fields still decodes (future compat)")
    func helloUnknownExtraFields() {
        let json = #"{"v":1,"msg":{"hello":{"_0":{"deviceName":"Mac B","peerID":"B","protocolVersion":1,"futureField":"x"}}}}"#
        guard case let .success(envelope) = EnvelopeCoding.decode(Data(json.utf8)),
              case let .hello(hello) = envelope.msg
        else {
            Issue.record("expected hello")
            return
        }
        #expect(hello.peerID == "B")
    }
}

@Suite("PairHello compat")
struct PairHelloCompatTests {
    @Test("PairHello without new optional fields decodes with nils")
    func missingOptionalFields() {
        let json = #"{"request":{"_0":{"peerID":"B","deviceName":"Mac B","publicKey":"","protocolVersion":1}}}"#
        guard case let .request(hello) = PairingMessageCoding.decode(Data(json.utf8)) else {
            Issue.record("expected request")
            return
        }
        #expect(hello.deviceKind == nil)
        #expect(hello.capabilities == nil)
        #expect(hello.syncPort == nil)
    }

    @Test("PairHello with new fields round-trips")
    func roundTripWithFields() throws {
        let hello = PairHello(
            peerID: "A",
            deviceName: "Mac A",
            publicKey: Data([1, 2, 3]),
            protocolVersion: 1,
            deviceKind: "mac",
            capabilities: ["als", "display", "audio"]
        )
        let data = try PairingMessageCoding.encode(.response(hello))
        guard case let .response(decoded) = PairingMessageCoding.decode(data) else {
            Issue.record("expected response")
            return
        }
        #expect(decoded == hello)
    }
}
