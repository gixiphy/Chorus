import Foundation

/// 配對通道（明文、僅配對視窗開啟期間存在）的訊息。
/// 安全性依賴 SAS：雙方畫面顯示同一 6 位數碼、由人比對確認，
/// 中間人替換公鑰會導致兩邊 SAS 不同而被人眼擋下。
public enum PairingMessage: Codable, Sendable, Equatable {
    /// 發起方 → 接受方。
    case request(PairHello)
    /// 接受方使用者按「接受」後回覆。
    case response(PairHello)
    /// 使用者確認 SAS 相符。雙方都送出 confirm 後配對完成。
    case confirm
    /// 任一方取消／拒絕。
    case abort
}

public struct PairHello: Codable, Sendable, Equatable {
    public let peerID: String
    public let deviceName: String
    /// Curve25519 公鑰 raw representation。
    public let publicKey: Data
    public let protocolVersion: Int
    /// 同步 listener 的固定 port（有值表示這台使用手動端點模式，
    /// 對方應記錄 host:port 作為 mDNS 之外的連線 fallback）。
    public let syncPort: Int?

    public init(peerID: String, deviceName: String, publicKey: Data, protocolVersion: Int, syncPort: Int? = nil) {
        self.peerID = peerID
        self.deviceName = deviceName
        self.publicKey = publicKey
        self.protocolVersion = protocolVersion
        self.syncPort = syncPort
    }
}

public enum PairingMessageCoding {
    public static func encode(_ message: PairingMessage) throws -> Data {
        try JSONEncoder().encode(message)
    }

    public static func decode(_ data: Data) -> PairingMessage? {
        try? JSONDecoder().decode(PairingMessage.self, from: data)
    }
}
