import Foundation

/// A device that completed pairing with this Mac.
struct PairedDevice: Codable, Identifiable, Equatable {
    let id: String              // client-generated stable UUID
    var name: String
    var presharedKey: Data      // 32 bytes, used for TLS-PSK and unlock signatures
    let pairedAt: Date
    var lastSeen: Date?
}

/// Persists paired devices as a JSON file with owner-only permissions.
///
/// Why a file and not the Keychain: the keys are needed at launch to configure
/// the TLS listener, and Keychain reads at launch trigger an access prompt on
/// every rebuild of an ad-hoc signed debug build. Anything able to read this
/// file already runs as the user and could control the Mac directly.
final class PairedDeviceStore {

    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.macremote.paired-devices")
    private var cache: [PairedDevice]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pedrocid.MacRemoteServer", isDirectory: true)
            try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            self.fileURL = support.appendingPathComponent("paired-devices.json")
        }
    }

    var devices: [PairedDevice] {
        queue.sync { load() }
    }

    func device(id: String) -> PairedDevice? {
        devices.first { $0.id == id }
    }

    func upsert(_ device: PairedDevice) {
        queue.sync {
            var all = load()
            if let index = all.firstIndex(where: { $0.id == device.id }) {
                all[index] = device
            } else {
                all.append(device)
            }
            save(all)
        }
    }

    func rename(id: String, to name: String) {
        queue.sync {
            var all = load()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return }
            all[index].name = name
            save(all)
        }
    }

    func touch(id: String) {
        queue.sync {
            var all = load()
            guard let index = all.firstIndex(where: { $0.id == id }) else { return }
            all[index].lastSeen = Date()
            save(all)
        }
    }

    func remove(id: String) {
        queue.sync {
            save(load().filter { $0.id != id })
        }
    }

    func removeAll() {
        queue.sync { save([]) }
    }

    // MARK: - Persistence (queue-confined)

    private func load() -> [PairedDevice] {
        if let cache { return cache }
        guard let data = try? Data(contentsOf: fileURL) else {
            cache = []
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = (try? decoder.decode([PairedDevice].self, from: data)) ?? []
        cache = decoded
        return decoded
    }

    private func save(_ devices: [PairedDevice]) {
        cache = devices
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(devices) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
