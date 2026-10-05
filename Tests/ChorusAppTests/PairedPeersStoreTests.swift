import ChorusCore
import Foundation
import Testing
@testable import Chorus

@MainActor
@Suite("已配對裝置的權限")
struct PairedPeersStoreTests {
    private let peerID = "peer-1"

    private func makeStore(
        _ peers: [PairedPeer],
        suite: String = "PairedPeersStoreTests.\(UUID().uuidString)"
    ) -> (PairedPeersStore, UserDefaults, KeychainStore) {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(try! JSONEncoder().encode(peers), forKey: "chorus.pairedPeers")
        let keychain = KeychainStore(service: suite)
        return (PairedPeersStore(defaults: defaults, keychain: keychain), defaults, keychain)
    }

    private func peer(permissions: PeerPermissionPolicy? = nil) -> PairedPeer {
        PairedPeer(peerID: peerID, deviceName: "Studio", pairedAt: Date(), permissions: permissions)
    }

    @Test("舊記錄沒有權限欄位 → 完整權限")
    func legacyRecordIsFull() {
        let (store, _, _) = makeStore([peer()])
        #expect(store.policy(for: peerID) == .full)
    }

    @Test("未配對的裝置只能查看")
    func unknownPeerIsViewOnly() {
        let (store, _, _) = makeStore([])
        #expect(store.policy(for: "stranger") == .viewOnly)
    }

    @Test("設定的權限跨重啟保留")
    func permissionsPersist() {
        let suite = "PairedPeersStoreTests.\(UUID().uuidString)"
        let (store, defaults, keychain) = makeStore([peer()], suite: suite)
        let limited = PeerPermissionPolicy(acceptsSync: false, allowedControls: [.audio])
        store.setPermissions(limited, for: peerID)
        let reloaded = PairedPeersStore(defaults: defaults, keychain: keychain)
        #expect(reloaded.policy(for: peerID) == limited)
    }

    @Test("重新配對同一台裝置不會重設權限")
    func addKeepsPermissions() {
        let limited = PeerPermissionPolicy.viewOnly
        let (store, _, keychain) = makeStore([peer(permissions: limited)])
        defer { _ = keychain.delete(account: "psk.\(peerID)") }
        store.add(peer(), psk: Data([1, 2, 3]))
        #expect(store.policy(for: peerID) == limited)
    }
}
