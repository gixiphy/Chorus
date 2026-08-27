import Foundation
import Observation

struct PairedPeer: Codable, Identifiable, Sendable, Equatable {
    let peerID: String
    var deviceName: String
    let pairedAt: Date
    /// mDNS 之外的連線 fallback（"host:port"）；配對時對方有固定 port 就記下。
    var manualEndpoint: String?
    /// 裝置類型："mac"；未來 iOS 伴侶 App 為 "iphone"/"ipad"。舊記錄無此欄 → nil。
    var deviceKind: String?
    /// 能力清單（如 ["als","display","audio"]），配對與每次 hello 時更新。
    var capabilities: [String]?

    var id: String { peerID }

    init(
        peerID: String,
        deviceName: String,
        pairedAt: Date,
        manualEndpoint: String? = nil,
        deviceKind: String? = nil,
        capabilities: [String]? = nil
    ) {
        self.peerID = peerID
        self.deviceName = deviceName
        self.pairedAt = pairedAt
        self.manualEndpoint = manualEndpoint
        self.deviceKind = deviceKind
        self.capabilities = capabilities
    }
}

/// 已配對裝置：metadata 存 UserDefaults、PSK 存 Keychain。
@MainActor
@Observable
final class PairedPeersStore {
    private static let peersKey = "chorus.pairedPeers"
    private static let pskAccountPrefix = "psk."

    private let defaults: UserDefaults
    private let keychain: KeychainStore

    private(set) var peers: [PairedPeer]

    init(defaults: UserDefaults, keychain: KeychainStore) {
        self.defaults = defaults
        self.keychain = keychain
        if let data = defaults.data(forKey: Self.peersKey),
           let decoded = try? JSONDecoder().decode([PairedPeer].self, from: data) {
            peers = decoded
        } else {
            peers = []
        }
    }

    func psk(for peerID: String) -> Data? {
        keychain.data(forAccount: Self.pskAccountPrefix + peerID)
    }

    func add(_ peer: PairedPeer, psk: Data) {
        keychain.set(psk, forAccount: Self.pskAccountPrefix + peer.peerID)
        peers.removeAll { $0.peerID == peer.peerID }
        peers.append(peer)
        persist()
    }

    func remove(peerID: String) {
        keychain.delete(account: Self.pskAccountPrefix + peerID)
        peers.removeAll { $0.peerID == peerID }
        persist()
    }

    func isPaired(_ peerID: String) -> Bool {
        peers.contains { $0.peerID == peerID }
    }

    /// 每次 sync hello 帶來的最新裝置資訊（名稱／類型／能力）寫回記錄。
    func updateMetadata(peerID: String, deviceName: String?, deviceKind: String?, capabilities: [String]?) {
        guard let index = peers.firstIndex(where: { $0.peerID == peerID }) else { return }
        var changed = false
        if let deviceName, peers[index].deviceName != deviceName {
            peers[index].deviceName = deviceName
            changed = true
        }
        if let deviceKind, peers[index].deviceKind != deviceKind {
            peers[index].deviceKind = deviceKind
            changed = true
        }
        if let capabilities, peers[index].capabilities != capabilities {
            peers[index].capabilities = capabilities
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(peers) {
            defaults.set(data, forKey: Self.peersKey)
        }
    }
}
