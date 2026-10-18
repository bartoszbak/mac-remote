import SwiftUI

struct SettingsView: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsMonitor

    var body: some View {
        TabView {
            GeneralSettings(manager: manager, settings: settings, permissions: permissions)
                .tabItem { Label("General", systemImage: "gearshape") }
            DevicesSettings(manager: manager, settings: settings)
                .tabItem { Label("Devices", systemImage: "iphone") }
            SecuritySettings(manager: manager, settings: settings)
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
    @ObservedObject var permissions: PermissionsMonitor
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
                WakeStatusRow(permissions: permissions)
                let interfaces = NetworkInterfaces.active()
                if !interfaces.isEmpty {
                    LabeledContent("Hardware address") {
                        Text(interfaces.map { "\($0.name) \($0.hardwareAddress)" }.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Text("Wake from Sleep")
            } footer: {
                Text("Your iPhone can wake this Mac with a network packet when Wake for network access is on. Works best over Ethernet, or over Wi‑Fi while plugged in.")
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
        .frame(height: 480)
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
    @State private var renamingID: String?
    @State private var renameText = ""

    var body: some View {
        Form {
            Section {
                if manager.pairedDevices.isEmpty {
                    Text("No paired devices yet. Pairing gives a device its own encrypted connection to this Mac.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.pairedDevices) { device in
                        pairedRow(device)
                    }
                }
                Button("Pair a Device…") {
                    manager.pairingRequested = true
                }
                .disabled(!manager.isRunning)
            } header: {
                Text("Paired Devices")
            } footer: {
                if !manager.isRunning {
                    Text("Turn on the server from the menu bar to pair.")
                }
            }

            Section {
                if manager.devices.isEmpty {
                    Text(manager.isRunning
                         ? "Open MacRemote on your iPhone and choose “\(manager.advertisedName ?? settings.effectiveServiceName)”."
                         : "Turn on the server from the menu bar so your iPhone can find this Mac.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.devices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: device.isSecure ? "lock.fill" : "lock.open")
                                .foregroundStyle(.secondary)
                                .help(device.isSecure ? "Encrypted connection" : "Unencrypted connection")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.displayName)
                                Text("\(device.address) · since \(device.connectedAt, style: .time)")
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
                    }
                }
            } header: {
                Text("Connected Now")
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }

    @ViewBuilder
    private func pairedRow(_ device: PairedDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                if renamingID == device.id {
                    TextField("Name", text: $renameText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { commitRename(device) }
                        .onExitCommand { renamingID = nil }
                } else {
                    Text(device.name)
                }
                Text(lastSeenText(device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if renamingID == device.id {
                Button("Save") { commitRename(device) }
                    .controlSize(.small)
            } else {
                Menu {
                    Button("Rename…") {
                        renameText = device.name
                        renamingID = device.id
                    }
                    Divider()
                    Button("Forget Device", role: .destructive) {
                        manager.forgetDevice(id: device.id)
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(.vertical, 2)
    }

    private func lastSeenText(_ device: PairedDevice) -> String {
        if manager.devices.contains(where: { $0.isPaired && $0.name == device.name && $0.isSecure }) {
            return String(localized: "Connected")
        }
        if let seen = device.lastSeen {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            return String(localized: "Last seen \(formatter.localizedString(for: seen, relativeTo: Date()))")
        }
        return String(localized: "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
    }

    private func commitRename(_ device: PairedDevice) {
        manager.renameDevice(id: device.id, to: renameText)
        renamingID = nil
    }
}

// MARK: - Security

private struct SecuritySettings: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var settings: AppSettings
    @State private var showingUnlockSheet = false

    var body: some View {
        Form {
            Section {
                Toggle("Allow unencrypted connections", isOn: $settings.allowUnencryptedConnections)
                LabeledContent("Encrypted port") {
                    Text(manager.securePort.map(String.init) ?? String(settings.tlsPort))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Encryption")
            } footer: {
                Text("Paired devices always connect over TLS. Turn this off once every device you use is paired, and unpaired devices on your network will no longer be able to control this Mac.")
            }

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

                }
            } header: {
                Text("Remote Unlock")
            } footer: {
                Text("The password never leaves this Mac. Only a paired iPhone can unlock it, after authenticating with Face ID or Touch ID, and only while the lock screen is showing.")
            }
        }
        .formStyle(.grouped)
        .frame(height: 440)
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
                }
            }
        )
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
                    PermissionStatusRow(granted: permissions.screenRecording, optional: false,
                                        request: permissions.requestScreenRecording)
                }
                .padding(.vertical, 2)
            } footer: {
                Text("Required. Lets MacRemote share the screen.")
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
