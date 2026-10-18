import Foundation
import Security

/// A Mac this phone has paired with. The pre-shared key is what proves it.
struct PairedMac: Codable, Identifiable, Equatable {
    let serverID: String
    var name: String
    let presharedKey: Data
    let pairedAt: Date

    var id: String { serverID }
}

/// Paired Macs, kept as one JSON blob in the Keychain (the keys are secrets).
final class PairedMacStore: ObservableObject {

    @Published private(set) var macs: [PairedMac] = []

    private let service = "com.pedrocid.MacRemoteClient.paired-macs"
    private let account = "paired-macs"
    private let inMemory: Bool

    /// Pass `inMemory: true` for previews so nothing touches the Keychain.
    init(inMemory: Bool = false) {
        self.inMemory = inMemory
        load()
    }

    func mac(serverID: String) -> PairedMac? {
        macs.first { $0.serverID == serverID }
    }

    func presharedKey(for serverID: String) -> Data? {
        mac(serverID: serverID)?.presharedKey
    }

    func upsert(_ mac: PairedMac) {
        if let index = macs.firstIndex(where: { $0.serverID == mac.serverID }) {
            macs[index] = mac
        } else {
            macs.append(mac)
        }
        save()
    }

    func forget(serverID: String) {
        macs.removeAll { $0.serverID == serverID }
        save()
    }

    // MARK: - Persistence

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private func load() {
        guard !inMemory else { return }
        var read = query
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(read as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        macs = (try? decoder.decode([PairedMac].self, from: data)) ?? []
    }

    private func save() {
        guard !inMemory else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(macs) else { return }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}
