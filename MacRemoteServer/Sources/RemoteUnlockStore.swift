import Foundation
import Security

final class RemoteUnlockStore {
    private enum Account {
        static let password = "mac-password"
        static let token = "pairing-token"
    }

    private let service = "com.pedrocid.MacRemoteServer.remote-unlock"

    /// The Mac login password, read from the Keychain only at the moment of unlocking.
    var password: String? {
        guard let data = read(account: Account.password) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Checks for the item without reading secret data, so this never triggers a
    /// Keychain access prompt. Safe to call at launch.
    var isConfigured: Bool {
        exists(account: Account.password)
    }

    @discardableResult
    func configure(password: String) -> Bool {
        let trimmedPassword = password.trimmingCharacters(in: .newlines)
        guard !trimmedPassword.isEmpty else { return false }
        return save(Data(trimmedPassword.utf8), account: Account.password)
    }

    func removeConfiguration() {
        delete(account: Account.password)
        // Clean up what earlier versions stored.
        delete(account: Account.token)
        if let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let legacy = support.appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pedrocid.MacRemoteServer", isDirectory: true)
                .appendingPathComponent("unlock-token")
            try? FileManager.default.removeItem(at: legacy)
        }
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
