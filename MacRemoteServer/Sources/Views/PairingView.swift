import SwiftUI

/// Shown automatically when a device asks to connect: who is asking, and the code
/// they must type. Closing the window declines the request.
struct PairingView: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var settings: AppSettings
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 20) {
            content
        }
        .padding(28)
        .frame(width: 420)
        .background(.windowBackground)
        .buttonBorderShape(.capsule)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            if manager.pairingSession == nil {
                dismissWindow(id: WindowID.pairing)
            }
        }
        .onDisappear {
            manager.closePairing()
        }
        .onChange(of: manager.pairingSession?.phase) { _, phase in
            if phase == .succeeded {
                Task {
                    try? await Task.sleep(for: .seconds(1.4))
                    dismissWindow(id: WindowID.pairing)
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let session = manager.pairingSession {
            switch session.phase {
            case .waitingForCode:
                request(session)
            case .succeeded:
                outcome(systemImage: "checkmark.circle.fill",
                        title: Text("\(session.deviceName) is connected"),
                        message: nil)
            case .failed(let reason):
                outcome(systemImage: "xmark.circle.fill",
                        title: Text("\(session.deviceName) was not connected"),
                        message: Text(reason))
            }
        } else {
            ProgressView().padding()
        }
    }

    private func request(_ session: ServerManager.PairingSession) -> some View {
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                    .font(.system(size: 36))
                    .foregroundStyle(.secondary)
                Text("\(session.deviceName) wants to connect")
                    .font(.title2.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Enter this code on the iPhone to let it control this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 14) {
                Text(formatted(session.code))
                    .font(.system(size: 44, weight: .semibold, design: .monospaced))
                    .tracking(6)
                    .textSelection(.enabled)
                CountdownRing(start: session.startedAt, end: session.expiresAt)
                    .frame(width: 28, height: 28)
            }
            .padding(.vertical, 4)

            HStack {
                Text("Didn't expect this? Decline it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Decline") {
                    manager.denyPairing()
                    dismissWindow(id: WindowID.pairing)
                }
                .keyboardShortcut(.cancelAction)
            }
        }
    }

    private func outcome(systemImage: String, title: Text, message: Text?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            title
                .font(.headline)
                .multilineTextAlignment(.center)
            if let message {
                message
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button("Done") { dismissWindow(id: WindowID.pairing) }
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
        }
        .padding(.vertical, 8)
    }

    private func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }
}

/// Shrinking ring that empties as the request runs out.
private struct CountdownRing: View {
    let start: Date
    let end: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.25)) { context in
            let total = end.timeIntervalSince(start)
            let remaining = max(0, end.timeIntervalSince(context.date))
            let fraction = total > 0 ? remaining / total : 0
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(Color.secondary, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(Int(remaining.rounded(.up)))")
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel("\(Int(remaining)) seconds remaining")
        }
    }
}
