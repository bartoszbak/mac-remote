import SwiftUI
import AppKit

// MARK: - Menu bar icon

/// Menu bar image per state. While a device is connected the item shows a bolt;
/// otherwise it shows the logo (two dots and a pill) in the label colour, with the
/// top dot tinted orange when attention is needed and the whole mark dimmed when off.
enum MenuBarIconRenderer {
    private static let height: CGFloat = 15

    // Geometry from the 43×43 logo, in its own coordinate space (y down).
    private static let logoSide: CGFloat = 43
    private static let dotRadius: CGFloat = 9.40625
    private static let topDotCenter = CGPoint(x: 9.40625, y: 9.40625)
    private static let bottomDotCenter = CGPoint(x: 9.40625, y: 33.59375)
    private static let pillRect = CGRect(x: 24.1875, y: 0, width: 18.8125, height: 43)

    static func image(for status: ServerManager.Status, connectedDevices: Int) -> NSImage {
        if case .running = status, connectedDevices > 0 {
            return connectedImage()
        }
        return logoImage(for: status)
    }

    private static func connectedImage() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        let symbol = NSImage(systemSymbolName: "bolt.horizontal.fill", accessibilityDescription: "MacRemote, device connected")!
            .withSymbolConfiguration(config)!
        symbol.isTemplate = true
        return symbol
    }

    private static func logoImage(for status: ServerManager.Status) -> NSImage {
        let scale = height / logoSide
        let size = NSSize(width: (logoSide * scale).rounded(.up), height: 18)

        let image = NSImage(size: size, flipped: true) { rect in
            let alpha: CGFloat = (status == .stopped) ? 0.45 : 1
            let base = NSColor.labelColor.withAlphaComponent(alpha)

            let topDotColor: NSColor
            if case .needsAttention = status {
                topDotColor = .systemOrange
            } else {
                topDotColor = base
            }

            let offsetY = (rect.height - logoSide * scale) / 2
            func point(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * scale, y: p.y * scale + offsetY)
            }
            func dot(at center: CGPoint, color: NSColor) {
                let r = dotRadius * scale
                let c = point(center)
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
            }

            dot(at: topDotCenter, color: topDotColor)
            dot(at: bottomDotCenter, color: base)

            let pill = CGRect(x: pillRect.minX * scale, y: pillRect.minY * scale + offsetY,
                              width: pillRect.width * scale, height: pillRect.height * scale)
            base.setFill()
            NSBezierPath(roundedRect: pill, xRadius: dotRadius * scale, yRadius: dotRadius * scale).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "MacRemote"
        return image
    }
}

// MARK: - Status helpers

extension ServerManager.Status {
    var color: Color {
        switch self {
        case .running: return .green
        case .starting: return .yellow
        case .stopped: return .secondary
        case .needsAttention: return .orange
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .running: return "Reachable"
        case .starting: return "Starting…"
        case .stopped: return "Off"
        case .needsAttention: return "Needs attention"
        }
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
}

// MARK: - Problem state

/// One icon, one sentence, one button.
struct ProblemView: View {
    let systemImage: String
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    let buttonTitle: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(buttonTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Permission row

/// Live permission status with a single call to action. Used by onboarding and Settings.
struct PermissionStatusRow: View {
    let granted: Bool
    let optional: Bool
    let request: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if granted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                Text("Access granted")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.small)
                Text(optional ? "Not granted" : "Waiting for access…")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open System Settings", action: request)
            }
        }
        .font(.callout)
    }
}

// MARK: - Wake for network access

struct WakeStatusRow: View {
    @ObservedObject var permissions: PermissionsMonitor

    var body: some View {
        LabeledContent("Wake for network access") {
            HStack(spacing: 8) {
                if permissions.wakeForNetworkAccess {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                    // Laptops only wake from the network on power; say so when battery is off.
                    Text(permissions.wakeForNetworkAccessOnBattery == false ? "On while plugged in" : "On")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Off").foregroundStyle(.secondary)
                    Button("Open Energy Settings") { permissions.requestWakeForNetworkAccess() }
                }
            }
        }
    }
}

// MARK: - Remote unlock sheet

struct RemoteUnlockSheet: View {
    @ObservedObject var manager: ServerManager
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Enable Remote Unlock", systemImage: "lock.open.fill")
                .font(.title3.weight(.semibold))

            Text("Your Mac login password is stored only in this Mac's Keychain. Paired devices send a one-time signature, never the password, and unlocking only works while the lock screen is showing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Mac login password", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(enable)

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Enable", action: enable)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .buttonBorderShape(.capsule)
    }

    private func enable() {
        if manager.configureRemoteUnlock(password: password) {
            dismiss()
        } else {
            error = "Enter your Mac login password."
        }
    }
}
