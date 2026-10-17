import SwiftUI

@main
struct MacRemoteServerApp: App {
    @StateObject private var settings: AppSettings
    @StateObject private var permissions: PermissionsMonitor
    @StateObject private var serverManager: ServerManager

    init() {
        let settings = AppSettings()
        let permissions = PermissionsMonitor()
        let manager = ServerManager(settings: settings, permissions: permissions)
        _settings = StateObject(wrappedValue: settings)
        _permissions = StateObject(wrappedValue: permissions)
        _serverManager = StateObject(wrappedValue: manager)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(manager: serverManager, settings: settings, permissions: permissions)
        } label: {
            MenuBarLabel(manager: serverManager, settings: settings)
        }
        .menuBarExtraStyle(.window)

        Window("Welcome to MacRemote", id: WindowID.onboarding) {
            OnboardingView(manager: serverManager, settings: settings, permissions: permissions)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        Window("Pair a Device", id: WindowID.pairing) {
            PairingView(manager: serverManager, settings: settings)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        Settings {
            SettingsView(manager: serverManager, settings: settings, permissions: permissions)
        }
    }
}

enum WindowID {
    static let onboarding = "onboarding"
    static let pairing = "pairing"
}

/// The status-bar item. Also the one view that is alive for the whole app
/// lifetime, so it owns "open onboarding on first launch".
struct MenuBarLabel: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var settings: AppSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIconRenderer.image(for: manager.status, connectedDevices: manager.connectedCount))
            .onAppear {
                if !settings.hasCompletedOnboarding {
                    showOnboarding()
                }
            }
            .onChange(of: manager.requestedOnboardingStep) { _, step in
                if step != nil {
                    showOnboarding()
                }
            }
            .onChange(of: manager.pairingRequested) { _, requested in
                if requested {
                    manager.pairingRequested = false
                    openWindow(id: WindowID.pairing)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
    }

    private func showOnboarding() {
        openWindow(id: WindowID.onboarding)
        NSApp.activate(ignoringOtherApps: true)
    }
}
