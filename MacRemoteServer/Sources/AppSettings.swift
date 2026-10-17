import Foundation
import ServiceManagement

/// User preferences for the Mac app, persisted in `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {

    private enum Keys {
        static let autoStartServer = "autoStartServer"
        static let serviceName = "serviceName"
        static let port = "port"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let showCursorInStream = "showCursorInStream"
        static let sharedDisplayID = "sharedDisplayID"
    }

    private let defaults: UserDefaults

    @Published var autoStartServer: Bool {
        didSet { defaults.set(autoStartServer, forKey: Keys.autoStartServer) }
    }

    /// The name other devices see when they discover this Mac.
    @Published var serviceName: String {
        didSet { defaults.set(serviceName, forKey: Keys.serviceName) }
    }

    @Published var port: Int {
        didSet { defaults.set(port, forKey: Keys.port) }
    }

    @Published var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding) }
    }

    @Published var showCursorInStream: Bool {
        didSet { defaults.set(showCursorInStream, forKey: Keys.showCursorInStream) }
    }

    /// `CGDirectDisplayID` of the display to share, or 0 for "whichever is main".
    @Published var sharedDisplayID: UInt32 {
        didSet { defaults.set(Int(sharedDisplayID), forKey: Keys.sharedDisplayID) }
    }

    @Published private(set) var launchAtLogin: Bool
    @Published var launchAtLoginError: String?

    static var defaultServiceName: String {
        Host.current().localizedName ?? NetworkConstants.serviceName
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.autoStartServer: true,
            Keys.port: Int(NetworkConstants.defaultPort),
            Keys.hasCompletedOnboarding: false,
            Keys.showCursorInStream: true,
            Keys.sharedDisplayID: 0
        ])
        autoStartServer = defaults.bool(forKey: Keys.autoStartServer)
        serviceName = defaults.string(forKey: Keys.serviceName) ?? Self.defaultServiceName
        port = defaults.integer(forKey: Keys.port)
        hasCompletedOnboarding = defaults.bool(forKey: Keys.hasCompletedOnboarding)
        showCursorInStream = defaults.bool(forKey: Keys.showCursorInStream)
        sharedDisplayID = UInt32(clamping: max(0, defaults.integer(forKey: Keys.sharedDisplayID)))
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    var effectivePort: UInt16 {
        UInt16(clamping: max(1, min(port, 65535)))
    }

    var effectiveServiceName: String {
        let trimmed = serviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultServiceName : trimmed
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            print("[Settings] Launch at login failed: \(error)")
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
