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
            .stateUpdate(StateUpdate(originID: "A", seq: 1, hlc: hlc, key: .brightness(displayUUID: nil), value: 0.5)),
            .command(Command(key: .volume(deviceUID: "uid-1"), value: 0.3)),
            .fullState(FullState(entries: [.init(key: .mute(deviceUID: nil), value: 1, hlc: hlc)])),
            .ping(7),
            .pong(7),
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
}
