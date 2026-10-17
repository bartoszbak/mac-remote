import Foundation
import CryptoKit

/// Key derivation and proofs for pairing. Shared by both apps so they derive
/// identical keys.
///
/// Flow (over the plaintext port, while the Mac shows a 6-digit code):
/// 1. Client → `pairRequest(deviceID, name, clientPublicKey)`
/// 2. Server → `pairChallenge(serverPublicKey, salt)`
/// 3. Both compute `sharedSecret` (X25519) and `sessionKey = HKDF(secret, salt, "session")`.
/// 4. Client → `pairConfirm(clientProof)` where `clientProof = HMAC(sessionKey, "client" ‖ code)`.
/// 5. Server verifies, replies `pairResult(success, serverProof = HMAC(sessionKey, "server" ‖ code))`.
/// 6. Both store `presharedKey = HKDF(secret, salt, "psk")` for TLS-PSK and unlock HMACs.
///
/// A passive observer learns nothing without the X25519 secret. An active
/// attacker gets a single guess at the code before the Mac closes the window.
enum PairingCrypto {

    static let codeLength = 6
    static let saltLength = 16

    private static let sessionInfo = Data("macremote-pairing-v2-session".utf8)
    private static let pskInfo = Data("macremote-pairing-v2-psk".utf8)
    private static let unlockInfo = Data("unlock".utf8)

    // MARK: Key agreement

    static func sharedSecret(privateKey: Curve25519.KeyAgreement.PrivateKey,
                             peerPublicKey: Data) throws -> SharedSecret {
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicKey)
        return try privateKey.sharedSecretFromKeyAgreement(with: peer)
    }

    static func sessionKey(from secret: SharedSecret, salt: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: sessionInfo, outputByteCount: 32)
    }

    static func presharedKey(from secret: SharedSecret, salt: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: salt, sharedInfo: pskInfo, outputByteCount: 32)
    }

    // MARK: Proofs

    static func clientProof(sessionKey: SymmetricKey, code: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("client".utf8) + Data(code.utf8), using: sessionKey))
    }

    static func serverProof(sessionKey: SymmetricKey, code: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("server".utf8) + Data(code.utf8), using: sessionKey))
    }

    /// Signature a paired device sends to unlock: HMAC over the server's challenge.
    static func unlockSignature(presharedKey: Data, challenge: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: challenge + unlockInfo, using: SymmetricKey(data: presharedKey)))
    }

    // MARK: Helpers

    static func randomCode() -> String {
        var value: UInt32 = 0
        repeat {
            var bytes = [UInt8](repeating: 0, count: 4)
            _ = SecRandomCopyBytes(kSecRandomDefault, 4, &bytes)
            value = bytes.withUnsafeBytes { $0.load(as: UInt32.self) }
        } while value >= 4_000_000_000 // reject to avoid modulo bias
        return String(format: "%06d", value % 1_000_000)
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        return Data(bytes)
    }

    static func normalizedCode(_ input: String) -> String? {
        let digits = input.filter(\.isNumber)
        return digits.count == codeLength ? digits : nil
    }

    static func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

extension SymmetricKey {
    var rawData: Data { withUnsafeBytes { Data($0) } }
}
