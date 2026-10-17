import SwiftUI

/// "Pair a Device" window: shows a 6-digit code with a countdown and reports the outcome.
struct PairingView: View {
    @ObservedObject var manager: ServerManager
    @ObservedObject var settings: AppSettings
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 20) {
            header
            codeArea
            footer
        }
        .padding(28)
        .frame(width: 420)
        .background(.windowBackground)
        .buttonBorderShape(.capsule)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            if manager.pairingSession?.isOpen != true {
                manager.startPairing()
            }
        }
        .onDisappear {
            manager.cancelPairing()
        }
        .onChange(of: manager.pairingSession?.phase) { _, phase in
            if case .succeeded = phase {
                Task {
                    try? await Task.sleep(for: .seconds(1.6))
                    dismissWindow(id: WindowID.pairing)
                }
            }
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone.and.arrow.right.inward")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Pair a Device")
                .font(.title2.weight(.semibold))
            Text("Open MacRemote on your iPhone, choose “\(manager.advertisedName ?? settings.effectiveServiceName)”, and enter this code.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var codeArea: some View {
        if let session = manager.pairingSession {
            switch session.phase {
            case .waiting, .inProgress:
                VStack(spacing: 14) {
                    Text(formatted(session.code))
                        .font(.system(size: 44, weight: .semibold, design: .monospaced))
                        .tracking(6)
                        .textSelection(.enabled)
                    CountdownRing(start: session.startedAt, end: session.expiresAt)
                        .frame(width: 28, height: 28)
                    if case .inProgress(let name) = session.phase {
                        Label("Connecting to \(name)…", systemImage: "ellipsis")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .symbolEffect(.variableColor.iterative, options: .repeating)
                    } else if !manager.isRunning {
                        Text("The server is off. Turn it on from the menu bar first.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            case .succeeded(let name):
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                        .transition(.scale.combined(with: .opacity))
                    Text("Paired with \(name)")
                        .font(.headline)
                }
                .padding(.vertical, 8)
            case .failed(let reason):
                VStack(spacing: 10) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.secondary)
                    Text(reason)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("New Code") { manager.startPairing() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 8)
            }
        } else {
            ProgressView().padding()
        }
    }

    private var footer: some View {
        HStack {
            Text("Pairing lets this device connect over an encrypted link, even when unencrypted connections are turned off.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Done") { dismissWindow(id: WindowID.pairing) }
                .keyboardShortcut(.cancelAction)
        }
    }

    private func formatted(_ code: String) -> String {
        guard code.count == 6 else { return code }
        return code.prefix(3) + " " + code.suffix(3)
    }
}

/// Shrinking ring that empties as the pairing window runs out.
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
