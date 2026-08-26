import CryptoKit
import Foundation

/// 配對金鑰交換：Curve25519 ECDH + HKDF。
///
/// 6 位數 PIN 只是 SAS（short authentication string）——雙方畫面各自顯示、
/// 由人比對確認，用來認證這次 key exchange 沒有被中間人替換；
/// **絕不作為金鑰材料**（Apple P2P 範例把短 PIN 導出 TLS-PSK 可被離線暴力破解）。
/// 確認後各自導出 32-byte 高熵 PSK 存 Keychain，日常連線走 TLS-PSK。
public enum PairingCrypto {
    public struct SessionSecrets: Equatable, Sendable {
        /// 32-byte 長期 pre-shared key。
        public let psk: Data
        /// 雙方畫面顯示的 6 位數確認碼。
        public let sasCode: String
    }

    public static func makePrivateKey() -> Curve25519.KeyAgreement.PrivateKey {
        Curve25519.KeyAgreement.PrivateKey()
    }

    /// 由本地私鑰與對方公鑰導出 PSK 與 SAS。
    /// 公鑰以「排序後串接」餵入 HKDF，確保雙方導出相同結果。
    public static func deriveSecrets(
        privateKey: Curve25519.KeyAgreement.PrivateKey,
        remotePublicKey: Data
    ) throws -> SessionSecrets {
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: remoteKey)

        let localPublicKey = privateKey.publicKey.rawRepresentation
        let sortedKeys = [localPublicKey, remotePublicKey].sorted { $0.lexicographicallyPrecedes($1) }
        let salt = sortedKeys[0] + sortedKeys[1]

        let pskKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("chorus-psk-v1".utf8),
            outputByteCount: 32
        )
        let sasKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("chorus-sas-v1".utf8),
            outputByteCount: 4
        )

        let psk = pskKey.withUnsafeBytes { Data($0) }
        let sasValue = sasKey.withUnsafeBytes { bytes in
            bytes.load(as: UInt32.self).bigEndian
        }
        let sasCode = String(format: "%06d", sasValue % 1_000_000)
        return SessionSecrets(psk: psk, sasCode: sasCode)
    }
}
