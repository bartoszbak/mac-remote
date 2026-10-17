#if DEBUG
import Foundation
import Network

/// Fixtures for Xcode previews. Nothing here ships in release builds.
extension NetworkClient {
    /// A client that looks connected (or not) without touching the network.
    static func preview(connected: Bool = true,
                        apps: [AppInfo] = AppInfo.previewApps,
                        unlockPaired: Bool = false,
                        screenLocked: Bool? = nil) -> NetworkClient {
        let client = NetworkClient(knownMacs: .preview())
        client.isConnected = connected
        client.setPreviewUnlockState(paired: unlockPaired, available: connected, locked: connected ? screenLocked : nil)
        client.connectedServerName = connected ? "Studio Mac" : nil
        client.screenSize = CGSize(width: 1920, height: 1080)
        client.apps = connected ? apps : []
        return client
    }
}

extension KnownMacStore {
    /// In-memory store holding one Mac that can be woken and one that cannot.
    static func preview() -> KnownMacStore {
        let store = KnownMacStore(defaults: nil)
        store.update(name: "Office iMac",
                     interfaces: [NetworkInterfaceInfo(name: "en0", hardwareAddress: "fc:b2:14:96:41:8b",
                                                       ipv4Address: "192.168.1.161", ipv4Broadcast: "192.168.1.255")],
                     wakeForNetworkAccessEnabled: true)
        store.update(name: "Old MacBook",
                     interfaces: [NetworkInterfaceInfo(name: "en0", hardwareAddress: "a4:83:e7:12:34:56",
                                                       ipv4Address: nil, ipv4Broadcast: nil)],
                     wakeForNetworkAccessEnabled: false)
        return store
    }
}

extension AppInfo {
    static let previewApps: [AppInfo] = [
        AppInfo(name: "Safari", bundleId: "com.apple.Safari", icon: nil),
        AppInfo(name: "Mail", bundleId: "com.apple.mail", icon: nil),
        AppInfo(name: "Music", bundleId: "com.apple.Music", icon: nil),
        AppInfo(name: "Xcode", bundleId: "com.apple.dt.Xcode", icon: nil),
        AppInfo(name: "Terminal", bundleId: "com.apple.Terminal", icon: nil),
        AppInfo(name: "Keynote", bundleId: "com.apple.iWork.Keynote", icon: nil)
    ]
}

extension BonjourBrowser {
    /// A browser pre-populated with discovered Macs.
    static func preview(serverNames: [String] = ["Studio Mac", "MacBook Pro"], searching: Bool = false) -> BonjourBrowser {
        let browser = BonjourBrowser()
        browser.isSearching = searching
        browser.servers = serverNames.map {
            DiscoveredServer(name: $0, endpoint: .hostPort(host: "192.168.1.10", port: 5150))
        }
        return browser
    }
}
#endif
