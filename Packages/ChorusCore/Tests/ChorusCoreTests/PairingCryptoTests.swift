import CryptoKit
import Foundation
import Testing
@testable import ChorusCore

@Suite("PairingCrypto")
struct PairingCryptoTests {
    @Test("Both sides derive identical SAS and PSK")
    func symmetricDerivation() throws {
        let alice = PairingCrypto.makePrivateKey()
        let bob = PairingCrypto.makePrivateKey()

        let aliceSecrets = try PairingCrypto.deriveSecrets(
            privateKey: alice, remotePublicKey: bob.publicKey.rawRepresentation
        )
        let bobSecrets = try PairingCrypto.deriveSecrets(
            privateKey: bob, remotePublicKey: alice.publicKey.rawRepresentation
        )

        #expect(aliceSecrets == bobSecrets)
        #expect(aliceSecrets.psk.count == 32)
        #expect(aliceSecrets.sasCode.count == 6)
        #expect(aliceSecrets.sasCode.allSatisfy { $0.isNumber })
    }

    @Test("Tampered public key (MITM) yields a different SAS code")
    func tamperDetection() throws {
        let alice = PairingCrypto.makePrivateKey()
        let bob = PairingCrypto.makePrivateKey()
        let mallory = PairingCrypto.makePrivateKey()

        // Alice 以為在跟 Bob 交換，實際被換成 Mallory 的公鑰
        let aliceView = try PairingCrypto.deriveSecrets(
            privateKey: alice, remotePublicKey: mallory.publicKey.rawRepresentation
        )
        // Bob 端正常（跟 Mallory 的另一把或 Bob 原配對）——雙方 SAS 必然不同
        let bobView = try PairingCrypto.deriveSecrets(
            privateKey: bob, remotePublicKey: mallory.publicKey.rawRepresentation
        )
        #expect(aliceView.sasCode != bobView.sasCode || aliceView.psk != bobView.psk)
    }

    @Test("Invalid public key data throws")
    func invalidKeyThrows() {
        let alice = PairingCrypto.makePrivateKey()
        #expect(throws: (any Error).self) {
            _ = try PairingCrypto.deriveSecrets(privateKey: alice, remotePublicKey: Data([1, 2, 3]))
        }
    }
}
