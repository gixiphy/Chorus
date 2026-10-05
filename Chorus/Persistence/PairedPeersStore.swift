import ChorusCore
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
    /// 這台 Mac 允許對方做什麼。nil ＝ 舊記錄 → 完整權限（與升級前一致）。
    var permissions: PeerPermissionPolicy?

    var id: String { peerID }

    init(
        peerID: String,
        deviceName: String,
        pairedAt: Date,
        manualEndpoint: String? = nil,
        deviceKind: String? = nil,
        capabilities: [String]? = nil,
        permissions: PeerPermissionPolicy? = nil
    ) {
        self.peerID = peerID
        self.deviceName = deviceName
        self.pairedAt = pairedAt
        self.manualEndpoint = manualEndpoint
        self.deviceKind = deviceKind
        self.capabilities = capabilities
        self.permissions = permissions
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

    /// 配對金鑰的狀態（診斷用，不讀出金鑰本身）。
    func keyState(for peerID: String) -> DoctorInputs.Peer.KeyState {
        switch keychain.itemStatus(forAccount: Self.pskAccountPrefix + peerID) {
        case errSecSuccess: .present
        case errSecItemNotFound: .missing
        case let status: .unreadable(status: status)
        }
    }

    func psk(for peerID: String) -> Data? {
        keychain.data(forAccount: Self.pskAccountPrefix + peerID)
    }

    func add(_ peer: PairedPeer, psk: Data) {
        keychain.set(psk, forAccount: Self.pskAccountPrefix + peer.peerID)
        var record = peer
        // 重新配對（換金鑰）不可以把使用者設的限制悄悄重設成完整權限
        if record.permissions == nil {
            record.permissions = peers.first { $0.peerID == peer.peerID }?.permissions
        }
        peers.removeAll { $0.peerID == peer.peerID }
        peers.append(record)
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

    /// 接收端判斷用。未配對的裝置（正常不會發生：沒有 PSK 連不進來）一律只能查看。
    func policy(for peerID: String) -> PeerPermissionPolicy {
        guard let peer = peers.first(where: { $0.peerID == peerID }) else { return .viewOnly }
        return peer.permissions ?? .full
    }

    func setPermissions(_ policy: PeerPermissionPolicy, for peerID: String) {
        guard let index = peers.firstIndex(where: { $0.peerID == peerID }),
              peers[index].permissions != policy
        else { return }
        peers[index].permissions = policy
        persist()
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
