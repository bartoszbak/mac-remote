import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsMonitor

    var body: some View {
        TabView {
            GeneralSettings(manager: manager, settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
            DevicesSettings(manager: manager, settings: settings)
                .tabItem { Label("Devices", systemImage: "iphone") }
            SecuritySettings(manager: manager)
                .tabItem { Label("Security", systemImage: "lock.shield") }
            PermissionsSettings(manager: manager, permissions: permissions)
                .tabItem { Label("Permissions", systemImage: "hand.raised") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
        .buttonBorderShape(.capsule)
        .onAppear { settings.refreshLaunchAtLogin() }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var settings: AppSettings
    @State private var portText = ""

    var body: some View {
        Form {
            Section {
                Toggle("Start the server automatically", isOn: $settings.autoStartServer)
                Toggle("Open MacRemote at login", isOn: launchAtLoginBinding)
                if let error = settings.launchAtLoginError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section {
                TextField("Mac name", text: $settings.serviceName, prompt: Text(AppSettings.defaultServiceName))
                    .onSubmit { manager.restartIfRunning() }
                TextField("Port", text: $portText)
                    .onSubmit(applyPort)
                    .onAppear { portText = String(settings.port) }
            } header: {
                Text("Network")
            } footer: {
                Text("This is the name your iPhone shows when it finds this Mac. Press Return to apply changes to a running server.")
            }

            Section {
                Picker("Display to share", selection: $settings.sharedDisplayID) {
                    Text("Main display").tag(UInt32(0))
                    ForEach(displays, id: \.id) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                Toggle("Show the cursor in the shared screen", isOn: $settings.showCursorInStream)
            } header: {
                Text("Screen Sharing")
            } footer: {
                if manager.isScreenStreaming {
                    Text("Display changes apply the next time a stream starts.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
    }

    private struct DisplayOption: Identifiable {
        let id: UInt32
        let name: String
    }

    private var displays: [DisplayOption] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let size = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
            return DisplayOption(id: number.uint32Value, name: "\(screen.localizedName) (\(size))")
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { settings.setLaunchAtLogin($0) }
        )
    }

    private func applyPort() {
        guard let value = Int(portText), (1...65535).contains(value) else {
            portText = String(settings.port)
            return
        }
        guard value != settings.port else { return }
        settings.port = value
        manager.restartIfRunning()
    }
}

// MARK: - Devices

private struct DevicesSettings: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var settings: AppSettings

    var body: some View {
        Group {
            if manager.devices.isEmpty {
                ContentUnavailableView {
                    Label("No devices connected", systemImage: "iphone.slash")
                } description: {
                    if manager.isRunning {
                        Text("Open MacRemote on your iPhone and choose “\(manager.advertisedName ?? settings.effectiveServiceName)”.")
                    } else {
                        Text("Turn on the server from the menu bar so your iPhone can find this Mac.")
                    }
                }
            } else {
                List(manager.devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: "iphone")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.address)
                            Text("Connected since \(device.connectedAt, style: .time)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if device.isStreaming {
                            Label("Streaming", systemImage: "display")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .frame(height: 320)
    }
}

// MARK: - Security

private struct SecuritySettings: View {
    @ObservedObject var manager: ServerManager
    @State private var showingUnlockSheet = false
    @State private var revealedPairingKey: String?
    @State private var copiedKey = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow unlocking this Mac from a paired iPhone", isOn: unlockBinding)

                if manager.isRemoteUnlockConfigured {
                    LabeledContent("Password") {
                        HStack {
                            Text("Stored in Keychain")
                                .foregroundStyle(.secondary)
                            Button("Change…") { showingUnlockSheet = true }
                        }
                    }

                    LabeledContent("Pairing key") {
                        HStack {
                            if let key = revealedPairingKey {
                                Text(key)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                            } else {
                                Text("Hidden")
                                    .foregroundStyle(.secondary)
                            }
                            Button(revealedPairingKey == nil ? "Reveal" : "Hide") {
                                revealedPairingKey = revealedPairingKey == nil ? manager.revealPairingKey() : nil
                            }
                            Button(copiedKey ? "Copied" : "Copy") {
                                copyPairingKey()
                            }
                        }
                    }
                }
            } header: {
                Text("Remote Unlock")
            } footer: {
                Text("The password never leaves this Mac. Your iPhone proves it holds the pairing key with a one-time signature and must authenticate with Face ID or Touch ID first. Unlocking only works while the lock screen is showing.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 320)
        .sheet(isPresented: $showingUnlockSheet) {
            RemoteUnlockSheet(manager: manager)
        }
    }

    private var unlockBinding: Binding<Bool> {
        Binding(
            get: { manager.isRemoteUnlockConfigured },
            set: { enabled in
                if enabled {
                    showingUnlockSheet = true
                } else {
                    manager.disableRemoteUnlock()
                    revealedPairingKey = nil
                }
            }
        )
    }

    private func copyPairingKey() {
        guard let key = revealedPairingKey ?? manager.revealPairingKey() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        copiedKey = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedKey = false }
    }
}

// MARK: - Permissions

private struct PermissionsSettings: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var permissions: PermissionsMonitor

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accessibility")
                    PermissionStatusRow(granted: permissions.accessibility, optional: false,
                                        request: permissions.requestAccessibility)
                }
                .padding(.vertical, 2)
            } footer: {
                Text("Required. Lets MacRemote move the mouse and type.")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Screen Recording")
                    PermissionStatusRow(granted: permissions.screenRecording, optional: true,
                                        request: permissions.requestScreenRecording)
                }
                .padding(.vertical, 2)
            } footer: {
                Text("Optional. Needed only for Screen Sharing.")
            }

            Section {
                Button("Run Setup Again…") {
                    manager.requestedOnboardingStep = .welcome
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 320)
    }
}

// MARK: - About

private struct AboutSettings: View {
    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 12) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 36)
            Text("MacRemote Server")
                .font(.title2.weight(.semibold))
            Text("Version \(version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Link("View on GitHub", destination: URL(string: "https://github.com/pedrocid/MacRemote")!)
                .font(.callout)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 320)
    }
}
