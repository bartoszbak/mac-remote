import Foundation
import Security

final class RemoteUnlockStore {
    private enum Account {
        static let password = "mac-password"
        static let token = "pairing-token"
    }

    private let service = "com.pedrocid.MacRemoteServer.remote-unlock"

    /// The legacy pairing token lives in an owner-only file, not the Keychain.
    /// Keychain items are bound to the signing identity, and a read denied after a
    /// rebuild made every unlock look like a wrong key. The login password stays in
    /// the Keychain; it is only read at the moment of unlocking.
    private let tokenFileURL: URL

    init(tokenFileURL: URL? = nil) {
        if let tokenFileURL {
            self.tokenFileURL = tokenFileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pedrocid.MacRemoteServer", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            self.tokenFileURL = support.appendingPathComponent("unlock-token")
        }
    }

    var password: String? {
        guard let data = read(account: Account.password) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Legacy pairing token. Migrates a token stored in the Keychain by earlier
    /// versions into the file on first successful read.
    var token: Data? {
        if let onDisk = try? Data(contentsOf: tokenFileURL), onDisk.count == 32 {
            return onDisk
        }
        guard let legacy = read(account: Account.token) else { return nil }
        if writeToken(legacy) {
            delete(account: Account.token)
            print("[RemoteUnlock] Migrated pairing token from Keychain to file")
        }
        return legacy
    }

    /// Whether a token can be used without a Keychain read.
    var hasFileToken: Bool {
        (try? Data(contentsOf: tokenFileURL))?.count == 32
    }

    /// Checks for the items without reading secret data, so this never triggers a
    /// Keychain access prompt. Safe to call at launch.
    var isConfigured: Bool {
        exists(account: Account.password) && (hasFileToken || exists(account: Account.token))
    }

    @discardableResult
    func configure(password: String) -> Bool {
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        guard !trimmedPassword.isEmpty else { return false }

        let passwordSaved = save(Data(trimmedPassword.utf8), account: Account.password)
        // Keep an existing token so already-paired phones stay valid.
        let tokenSaved = token != nil || writeToken(Self.randomBytes(count: 32))
        return passwordSaved && tokenSaved
    }

    func removeConfiguration() {
        delete(account: Account.password)
        delete(account: Account.token)
        try? FileManager.default.removeItem(at: tokenFileURL)
    }

    private func writeToken(_ data: Data) -> Bool {
        do {
            try data.write(to: tokenFileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFileURL.path)
            return true
        } catch {
            print("[RemoteUnlock] Failed to write token: \(error)")
            return false
        }
    }

    var formattedPairingKey: String? {
        token?.map { String(format: "%02X", $0) }
            .joined()
            .split(every: 8)
            .joined(separator: "-")
    }

    static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return Data(UUID().uuidString.utf8)
        }
        return Data(bytes)
    }

    private func save(_ data: Data, account: String) -> Bool {
        delete(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecValueData as String: data
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private func exists(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: false,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    private func read(account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else {
            return nil
        }
        return result as? Data
    }

    private func delete(account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private extension Collection {
    func split(every size: Int) -> [SubSequence] {
        guard size > 0 else { return [self[startIndex..<endIndex]] }
        return stride(from: 0, to: count, by: size).map { offset in
            let start = index(startIndex, offsetBy: offset)
            let end = index(start, offsetBy: Swift.min(size, count - offset))
            return self[start..<end]
        }
    }
}
