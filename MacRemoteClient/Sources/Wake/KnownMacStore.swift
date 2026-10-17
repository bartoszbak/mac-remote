import Foundation

/// A Mac this phone has connected to before, with what is needed to wake it from sleep.
struct KnownMac: Codable, Identifiable, Equatable {
    /// The Bonjour service name, which is how the Mac is identified until pairing lands.
    let name: String
    var interfaces: [NetworkInterfaceInfo]
    var wakeForNetworkAccessEnabled: Bool
    var lastSeen: Date

    var id: String { name }

    /// Interfaces with a hardware address a magic packet can target.
    var wakeableInterfaces: [NetworkInterfaceInfo] {
        interfaces.filter { WakeOnLAN.parseHardwareAddress($0.hardwareAddress) != nil }
    }

    var canWake: Bool {
        wakeForNetworkAccessEnabled && !wakeableInterfaces.isEmpty
    }
}

/// Remembers Macs seen before, in UserDefaults. Wake info changes rarely, so the store is
/// refreshed from the `wakeInfo` message on every connection.
final class KnownMacStore: ObservableObject {

    @Published private(set) var macs: [KnownMac] = []

    private let defaults: UserDefaults?
    private let key = "knownMacs"

    /// Pass `nil` for an in-memory store, as previews do.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        load()
    }

    /// Most recently used first.
    var byRecency: [KnownMac] {
        macs.sorted { $0.lastSeen > $1.lastSeen }
    }

    func mac(named name: String) -> KnownMac? {
        macs.first { $0.name == name }
    }

    func update(name: String, interfaces: [NetworkInterfaceInfo], wakeForNetworkAccessEnabled: Bool) {
        let entry = KnownMac(name: name,
                             interfaces: interfaces,
                             wakeForNetworkAccessEnabled: wakeForNetworkAccessEnabled,
                             lastSeen: Date())
        if let index = macs.firstIndex(where: { $0.name == name }) {
            macs[index] = entry
        } else {
            macs.append(entry)
        }
        save()
    }

    func forget(name: String) {
        macs.removeAll { $0.name == name }
        save()
    }

    private func load() {
        guard let data = defaults?.data(forKey: key),
              let decoded = try? JSONDecoder().decode([KnownMac].self, from: data) else { return }
        macs = decoded
    }

    private func save() {
        guard let defaults else { return }
        if let data = try? JSONEncoder().encode(macs) {
            defaults.set(data, forKey: key)
        }
    }
}
