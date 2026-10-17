import SwiftUI

/// The menu bar popover. Answers one question at a glance, "is my Mac reachable
/// from my phone?", and reveals more only when there is something to show.
struct MenuBarView: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsMonitor
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

            Divider()

            content
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .frame(width: 300)
        .buttonBorderShape(.capsule)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(settings.effectiveServiceName)
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    StatusDot(color: manager.status.color)
                    statusLine
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Toggle("Server", isOn: serverBinding)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(manager.problem == .accessibilityMissing)
                .help(manager.isRunning ? "Stop sharing this Mac" : "Make this Mac reachable")
            overflowMenu
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("Pair a Device…") {
                manager.pairingRequested = true
            }
            .disabled(!manager.isRunning)
            Button("Settings…") {
                showSettings()
            }
            .keyboardShortcut(",", modifiers: .command)
            Button("Run Setup Again…") {
                manager.requestedOnboardingStep = .welcome
            }
            Divider()
            Button("About MacRemote") {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.orderFrontStandardAboutPanel(nil)
            }
            Divider()
            Button("Quit MacRemote") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        } label: {
            Image(systemName: "ellipsis")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .background(.quaternary, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More")
    }

    private var statusLine: Text {
        switch manager.status {
        case .running:
            let count = manager.connectedCount
            if count == 0 {
                return Text("Reachable")
            } else if count == 1 {
                return Text("Reachable · 1 device")
            } else {
                return Text("Reachable · \(count) devices")
            }
        default:
            return Text(manager.status.title)
        }
    }

    private var serverBinding: Binding<Bool> {
        Binding(
            get: { manager.status == .running || manager.status == .starting },
            set: { _ in manager.toggle() }
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if let problem = manager.problem {
            problemView(problem)
        } else if manager.isRunning {
            VStack(alignment: .leading, spacing: 12) {
                devicesSection
                if let activity = manager.lastActivity {
                    activityLine(activity)
                }
            }
        } else if manager.status == .starting {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Starting the server…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else {
            Text("Turn on the switch to let your iPhone find this Mac.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func problemView(_ problem: ServerManager.Problem) -> some View {
        switch problem {
        case .accessibilityMissing:
            ProblemView(
                systemImage: "hand.raised.fill",
                title: "Accessibility access needed",
                message: "MacRemote needs Accessibility access to move the mouse and type on your behalf.",
                buttonTitle: "Fix…"
            ) {
                manager.requestedOnboardingStep = .accessibility
            }
        case .portInUse(let port):
            ProblemView(
                systemImage: "network.slash",
                title: "Port \(port) is in use",
                message: "Another app is using this port. Choose a different one in Settings.",
                buttonTitle: "Choose Another Port…"
            ) {
                showSettings()
            }
        case .listenerFailed(let message):
            ProblemView(
                systemImage: "exclamationmark.triangle.fill",
                title: "Couldn't start the server",
                message: "\(message)",
                buttonTitle: "Try Again"
            ) {
                manager.start()
            }
        }
    }

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devices")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if manager.devices.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "iphone.radiowaves.left.and.right")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Waiting for a device")
                            .font(.callout)
                        Text("Open MacRemote on your iPhone and choose “\(manager.advertisedName ?? settings.effectiveServiceName)”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                ForEach(manager.devices) { device in
                    HStack(spacing: 10) {
                        StatusDot(color: .green)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.displayName)
                                .font(.callout)
                            Text("Connected since \(device.connectedAt, style: .time)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: device.isSecure ? "lock.fill" : "lock.open")
                            .foregroundStyle(.secondary)
                            .help(device.isSecure ? "Encrypted connection" : "Unencrypted connection")
                        if device.isStreaming {
                            Image(systemName: "display")
                                .foregroundStyle(.secondary)
                                .help("Streaming the screen to this device")
                        }
                    }
                }
            }
        }
    }

    private func activityLine(_ activity: ServerManager.Activity) -> some View {
        HStack(spacing: 8) {
            Image(systemName: activityIcon(activity))
                .foregroundStyle(.secondary)
                .frame(width: 24)
            activityText(activity)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
    }

    private func activityIcon(_ activity: ServerManager.Activity) -> String {
        switch activity {
        case .streaming: return "display"
        case .unlockSent: return "lock.open"
        case .unlockRejected: return "lock.trianglebadge.exclamationmark"
        case .appLaunched: return "arrow.up.forward.app"
        case .paired: return "link"
        }
    }

    private func activityText(_ activity: ServerManager.Activity) -> Text {
        switch activity {
        case .streaming(let address, let quality):
            return Text("Streaming to \(address) · \(qualityName(quality))")
        case .unlockSent(let date):
            return Text("Unlock sent \(date, style: .relative) ago")
        case .unlockRejected(let date):
            return Text("Unlock rejected \(date, style: .relative) ago")
        case .appLaunched(let bundleId, let date):
            return Text("Launched \(bundleId) \(date, style: .relative) ago")
        case .paired(let name, let date):
            return Text("Paired with \(name) \(date, style: .relative) ago")
        }
    }

    private func qualityName(_ quality: RemoteMessage.StreamQuality) -> String {
        switch quality {
        case .low: return "480p"
        case .medium: return "720p"
        case .high: return "1080p"
        }
    }

    private func showSettings() {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
    }
}
