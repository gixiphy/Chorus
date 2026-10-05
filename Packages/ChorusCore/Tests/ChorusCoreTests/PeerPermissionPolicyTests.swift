import Foundation
import Testing
@testable import ChorusCore

@Suite("PeerPermissionPolicy")
struct PeerPermissionPolicyTests {
    private let hlc = HLCTimestamp(wallMicros: 1, counter: 0, peerID: "B")

    private func update(_ key: ControlKey) -> SyncMessage {
        .stateUpdate(StateUpdate(originID: "B", seq: 1, hlc: hlc, key: key, value: 0.5))
    }

    private func endpointCommand(_ capability: RemoteEndpointCapability, id: UUID = UUID()) -> SyncMessage {
        .endpointCommand(EndpointCommand(id: id, deviceID: "D1", kind: .display, capability: capability, value: 0.5))
    }

    @Test("Full policy admits every message")
    func fullAdmitsAll() {
        let policy = PeerPermissionPolicy.full
        #expect(policy.admission(for: update(.brightness(displayUUID: nil))) == .allow)
        #expect(policy.admission(for: .command(Command(key: .displayPower(displayUUID: nil), value: 0))) == .allow)
        #expect(policy.admission(for: .setDeviceOffset(DeviceOffsetCommand(offset: 0.1))) == .allow)
        #expect(policy.admission(for: endpointCommand(.volume)) == .allow)
    }

    @Test("View-only drops sync and commands but answers queries")
    func viewOnly() {
        let policy = PeerPermissionPolicy.viewOnly
        let id = UUID()
        #expect(policy.admission(for: update(.volume(deviceUID: nil))) == .drop)
        #expect(policy.admission(for: .fullState(FullState(entries: []))) == .drop)
        #expect(policy.admission(for: .ambientReport(AmbientReport(originID: "B", hlc: hlc, lux: 100))) == .drop)
        #expect(policy.admission(for: .command(Command(key: .volume(deviceUID: nil), value: 0.2))) == .drop)
        #expect(policy.admission(for: endpointCommand(.brightness, id: id)) == .rejectEndpointCommand(id: id))
        #expect(policy.admission(for: .stateQuery(StateQuery())) == .allow)
        #expect(policy.admission(for: .deviceDirectoryQuery(DeviceDirectoryQuery())) == .allow)
        #expect(policy.admission(for: .ping(1)) == .allow)
    }

    @Test("Controls map to the right class")
    func controlMapping() {
        let audioOnly = PeerPermissionPolicy(acceptsSync: false, allowedControls: [.audio])
        #expect(audioOnly.allows(.volume(deviceUID: nil)))
        #expect(audioOnly.allows(.appMute(bundleID: "com.apple.Music")))
        #expect(!audioOnly.allows(.input(displayUUID: "X")))
        #expect(!audioOnly.allows(.contrast(displayUUID: "X")))
        #expect(PeerPermissionPolicy.Control(.input(displayUUID: nil)) == .displayPower)
        #expect(PeerPermissionPolicy.Control(.contrast(displayUUID: nil)) == .brightness)
        #expect(PeerPermissionPolicy.Control(.keepAwake(displayUUID: nil)) == .keepAwake)
        #expect(audioOnly.admission(for: .setDeviceOffset(DeviceOffsetCommand(offset: 0.1))) == .drop)
    }

    @Test("Sync acceptance is independent of command permissions")
    func syncIndependent() {
        let policy = PeerPermissionPolicy(acceptsSync: true, allowedControls: [])
        #expect(policy.admission(for: update(.brightness(displayUUID: nil))) == .allow)
        #expect(policy.admission(for: .command(Command(key: .brightness(displayUUID: nil), value: 0.3))) == .drop)
    }

    @Test("Unknown endpoint capability is rejected even with full policy")
    func unknownCapabilityRejected() {
        let id = UUID()
        let message = endpointCommand(RemoteEndpointCapability(rawValue: "hue"), id: id)
        #expect(PeerPermissionPolicy.full.admission(for: message) == .rejectEndpointCommand(id: id))
    }

    @Test("Decoding tolerates control classes from newer versions")
    func decodesUnknownControl() throws {
        let json = Data(#"{"acceptsSync":true,"allowedControls":["audio","scenes"]}"#.utf8)
        let policy = try JSONDecoder().decode(PeerPermissionPolicy.self, from: json)
        #expect(policy.allowedControls.contains(.audio))
        #expect(policy.allowedControls.contains(PeerPermissionPolicy.Control(rawValue: "scenes")))
        #expect(!policy.allowedControls.contains(.brightness))
    }

    @Test("Round-trips through JSON")
    func roundTrip() throws {
        let policy = PeerPermissionPolicy(acceptsSync: false, allowedControls: [.brightness, .keepAwake])
        let decoded = try JSONDecoder().decode(PeerPermissionPolicy.self, from: JSONEncoder().encode(policy))
        #expect(decoded == policy)
    }
}
