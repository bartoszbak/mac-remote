import Foundation

enum NetworkConstants {
    static let serviceType = "_macremote._tcp"
    static let serviceDomain = "local."
    static let serviceName = "MacRemote"

    /// Plaintext port. Used for discovery, pairing and (while allowed) legacy control.
    static let defaultPort: UInt16 = 5150

    /// The encrypted (TLS-PSK) listener runs on `defaultPort + tlsPortOffset` by default.
    static let tlsPortOffset: UInt16 = 1

    /// Bumped when messages are added. v1: original protocol. v2: hello, pairing, welcome.
    static let protocolVersion = 2

    /// Bonjour TXT record keys.
    enum TXTKey {
        static let tlsPort = "tlsPort"
        static let protocolVersion = "v"
    }
}
