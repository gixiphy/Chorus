import Foundation
import Network
import Security

/// TLS-PSK 連線參數。
///
/// 設計：TLS 1.2 + PSK（`sec_protocol_options` 不支援 TLS 1.3 PSK）。
/// PSK 為配對時 ECDH+HKDF 導出的 32-byte 高熵金鑰，TLS 1.2 PSK 在此強度下安全。
/// PSK identity hint 一律為「撥號方的 peerID」：listener 端把每個已配對 peer 的
/// PSK 以其 peerID 為 identity 全部註冊，握手時由 TLS 層依 hint 配對。
enum ChorusTLS {
    /// TLS_PSK_WITH_AES_128_GCM_SHA256（RFC 5487，raw 0x00A8）。
    private static let pskCipherSuiteRaw: UInt16 = 0x00A8

    static func parameters(psks: [(identity: String, psk: Data)]) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        for entry in psks {
            let pskDispatch = entry.psk.withUnsafeBytes { DispatchData(bytes: $0) }
            let identityDispatch = Data(entry.identity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
            sec_protocol_options_add_pre_shared_key(
                sec,
                pskDispatch as __DispatchData,
                identityDispatch as __DispatchData
            )
        }
        if let suite = tls_ciphersuite_t(rawValue: pskCipherSuiteRaw) {
            sec_protocol_options_append_tls_ciphersuite(sec, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

        let params = NWParameters(tls: tls, tcp: tcpOptions())
        params.includePeerToPeer = false
        return params
    }

    /// 配對通道用的明文 TCP（安全性由 SAS 人工比對承擔，僅配對期間存在）。
    static func plaintextParameters() -> NWParameters {
        let params = NWParameters(tls: nil, tcp: tcpOptions())
        params.includePeerToPeer = false
        return params
    }

    private static func tcpOptions() -> NWProtocolTCP.Options {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 15
        return tcp
    }
}
