import Foundation
import Security
import Testing
@testable import Chorus

@Suite("Keychain 項目狀態")
struct KeychainStoreStatusTests {
    @Test("不存在的項目回 errSecItemNotFound，寫入後回 errSecSuccess")
    func itemStatus() {
        let keychain = KeychainStore(service: "KeychainStoreStatusTests.\(UUID().uuidString)")
        defer { _ = keychain.delete(account: "psk.peer") }
        #expect(keychain.itemStatus(forAccount: "psk.peer") == errSecItemNotFound)
        keychain.set(Data([1, 2, 3]), forAccount: "psk.peer")
        #expect(keychain.itemStatus(forAccount: "psk.peer") == errSecSuccess)
    }
}
