import XCTest
import CryptoKit
@testable import MacRemoteServer

final class PairingCryptoTests: XCTestCase {

    func testRandomCodeIsSixDigits() {
        for _ in 0..<50 {
            let code = PairingCrypto.randomCode()
            XCTAssertEqual(code.count, 6)
            XCTAssertTrue(code.allSatisfy(\.isNumber), code)
        }
    }

    func testNormalizedCodeAcceptsSpacedInputAndRejectsOthers() {
        XCTAssertEqual(PairingCrypto.normalizedCode("123 456"), "123456")
        XCTAssertEqual(PairingCrypto.normalizedCode(" 1-2-3-4-5-6 "), "123456")
        XCTAssertNil(PairingCrypto.normalizedCode("12345"))
        XCTAssertNil(PairingCrypto.normalizedCode("1234567"))
        XCTAssertNil(PairingCrypto.normalizedCode("abcdef"))
    }

    /// Simulates both ends of the handshake and checks they agree on every derived value.
    func testHandshakeDerivesMatchingKeysAndProofs() throws {
        let code = "482913"
        let client = Curve25519.KeyAgreement.PrivateKey()
        let server = Curve25519.KeyAgreement.PrivateKey()
        let salt = PairingCrypto.randomBytes(PairingCrypto.saltLength)

        let clientSecret = try PairingCrypto.sharedSecret(privateKey: client, peerPublicKey: server.publicKey.rawRepresentation)
        let serverSecret = try PairingCrypto.sharedSecret(privateKey: server, peerPublicKey: client.publicKey.rawRepresentation)

        let clientSession = PairingCrypto.sessionKey(from: clientSecret, salt: salt)
        let serverSession = PairingCrypto.sessionKey(from: serverSecret, salt: salt)
        XCTAssertEqual(clientSession.rawData, serverSession.rawData)

        let clientPSK = PairingCrypto.presharedKey(from: clientSecret, salt: salt)
        let serverPSK = PairingCrypto.presharedKey(from: serverSecret, salt: salt)
        XCTAssertEqual(clientPSK.rawData, serverPSK.rawData)
        XCTAssertEqual(clientPSK.rawData.count, 32)
        XCTAssertNotEqual(clientPSK.rawData, clientSession.rawData, "session and long-term keys must differ")

        let proof = PairingCrypto.clientProof(sessionKey: clientSession, code: code)
        XCTAssertTrue(PairingCrypto.constantTimeEquals(proof, PairingCrypto.clientProof(sessionKey: serverSession, code: code)))

        let serverProof = PairingCrypto.serverProof(sessionKey: serverSession, code: code)
        XCTAssertTrue(PairingCrypto.constantTimeEquals(serverProof, PairingCrypto.serverProof(sessionKey: clientSession, code: code)))
        XCTAssertFalse(PairingCrypto.constantTimeEquals(proof, serverProof))
    }

    func testWrongCodeProducesDifferentProof() throws {
        let key = SymmetricKey(size: .bits256)
        let right = PairingCrypto.clientProof(sessionKey: key, code: "111111")
        let wrong = PairingCrypto.clientProof(sessionKey: key, code: "111112")
        XCTAssertFalse(PairingCrypto.constantTimeEquals(right, wrong))
    }

    func testDifferentSaltsProduceDifferentKeys() throws {
        let client = Curve25519.KeyAgreement.PrivateKey()
        let server = Curve25519.KeyAgreement.PrivateKey()
        let secret = try PairingCrypto.sharedSecret(privateKey: client, peerPublicKey: server.publicKey.rawRepresentation)
        let a = PairingCrypto.presharedKey(from: secret, salt: Data(repeating: 1, count: 16))
        let b = PairingCrypto.presharedKey(from: secret, salt: Data(repeating: 2, count: 16))
        XCTAssertNotEqual(a.rawData, b.rawData)
    }

    func testInvalidPeerKeyThrows() {
        let key = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try PairingCrypto.sharedSecret(privateKey: key, peerPublicKey: Data([1, 2, 3])))
    }

    func testUnlockSignatureIsDeterministic() {
        let psk = PairingCrypto.randomBytes(32)
        let challenge = PairingCrypto.randomBytes(32)
        XCTAssertEqual(PairingCrypto.unlockSignature(presharedKey: psk, challenge: challenge),
                       PairingCrypto.unlockSignature(presharedKey: psk, challenge: challenge))
        XCTAssertNotEqual(PairingCrypto.unlockSignature(presharedKey: psk, challenge: challenge),
                          PairingCrypto.unlockSignature(presharedKey: psk, challenge: PairingCrypto.randomBytes(32)))
    }
}
