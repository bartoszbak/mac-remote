import SwiftUI

/// First-run setup. Each permission step deep-links to System Settings and
/// completes itself the moment the permission is granted.
struct OnboardingView: View {
    typealias Step = ServerManager.OnboardingStep

    @ObservedObject var manager: ServerManager
    @ObservedObject var settings: AppSettings
    @ObservedObject var permissions: PermissionsMonitor
    @Environment(\.dismissWindow) private var dismissWindow

    @State private var step: Step = .welcome

    var body: some View {
        VStack(spacing: 0) {
            StepIndicator(current: step)
                .padding(.top, 24)

            Spacer(minLength: 0)

            stepContent
                .frame(maxWidth: 420)
                .padding(.horizontal, 40)
                .id(step)
                .transition(.opacity.combined(with: .move(edge: .trailing)))

            Spacer(minLength: 0)

            footer
                .padding(20)
        }
        .frame(width: 560, height: 460)
        .background(.windowBackground)
        .buttonBorderShape(.capsule)
        .animation(.easeInOut(duration: 0.2), value: step)
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            consumeRequestedStep()
        }
        .onChange(of: manager.requestedOnboardingStep) { _, _ in
            consumeRequestedStep()
        }
    }

    private func consumeRequestedStep() {
        if let requested = manager.requestedOnboardingStep {
            step = requested
            manager.requestedOnboardingStep = nil
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .welcome:
            welcome
        case .accessibility:
            permissionStep(
                systemImage: "hand.point.up.left.fill",
                title: "Allow Accessibility access",
                explanation: "MacRemote moves the mouse and types on your behalf. macOS requires Accessibility access for that.",
                hint: "In System Settings, turn on MacRemote Server under Accessibility, then come back here.",
                granted: permissions.accessibility,
                optional: false,
                request: permissions.requestAccessibility
            )
        case .screenRecording:
            permissionStep(
                systemImage: "rectangle.inset.filled.and.person.filled",
                title: "Allow Screen Recording",
                explanation: "Needed only for Screen Sharing, so you can see your Mac's screen on your iPhone. You can skip this and enable it later.",
                hint: permissions.screenRecording
                    ? "If screen sharing does not work right away, quit and reopen MacRemote."
                    : "In System Settings, turn on MacRemote Server under Screen & System Audio Recording.",
                granted: permissions.screenRecording,
                optional: true,
                request: permissions.requestScreenRecording
            )
        case .start:
            startStep
        case .done:
            done
        }
    }

    private var welcome: some View {
        VStack(spacing: 16) {
            Image("MenuBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(height: 44)
                .foregroundStyle(.secondary)
            Text("Welcome to MacRemote")
                .font(.largeTitle.weight(.semibold))
            Text("Control this Mac from your iPhone: trackpad, keyboard, media keys, app launcher and screen sharing. Let's set up the permissions it needs.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func permissionStep(
        systemImage: String,
        title: LocalizedStringKey,
        explanation: LocalizedStringKey,
        hint: LocalizedStringKey,
        granted: Bool,
        optional: Bool,
        request: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
            HStack(spacing: 8) {
                Text(title)
                    .font(.title.weight(.semibold))
                if optional {
                    Text("Optional")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                }
            }
            Text(explanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    PermissionStatusRow(granted: granted, optional: optional, request: request)
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(6)
            }
        }
    }

    private var startStep: some View {
        VStack(spacing: 16) {
            Image(systemName: manager.isRunning ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
                .contentTransition(.symbolEffect(.replace))
            Text("Make this Mac reachable")
                .font(.title.weight(.semibold))
            Text("Your iPhone finds this Mac automatically when both are on the same network.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        StatusDot(color: manager.status.color)
                        if manager.isRunning {
                            Text("Reachable as “\(manager.advertisedName ?? settings.effectiveServiceName)”")
                        } else {
                            Text(manager.status.title)
                        }
                        Spacer()
                        if !manager.isRunning {
                            Button("Start") { manager.start() }
                                .disabled(manager.status == .starting || manager.problem != nil)
                        }
                    }
                    .font(.callout)

                    Divider()

                    Toggle("Open MacRemote at login", isOn: launchAtLoginBinding)
                        .font(.callout)
                    if let error = settings.launchAtLoginError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .padding(6)
            }
        }
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("You're all set")
                .font(.largeTitle.weight(.semibold))
            Text("MacRemote lives in your menu bar. Click its icon to see connected devices, pause sharing, or change settings.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { settings.launchAtLogin },
            set: { settings.setLaunchAtLogin($0) }
        )
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done {
                Button("Back") { go(to: previous) }
            }
            Spacer()
            if step == .screenRecording && !permissions.screenRecording {
                Button("Skip") { go(to: .start) }
            }
            Button(step == .done ? "Finish" : "Continue") {
                if step == .done {
                    finish()
                } else {
                    go(to: next)
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!canContinue)
        }
    }

    private var canContinue: Bool {
        switch step {
        case .welcome, .start, .done: return true
        case .accessibility: return permissions.accessibility
        case .screenRecording: return permissions.screenRecording
        }
    }

    private var next: Step {
        Step(rawValue: step.rawValue + 1) ?? .done
    }

    private var previous: Step {
        Step(rawValue: step.rawValue - 1) ?? .welcome
    }

    private func go(to newStep: Step) {
        step = newStep
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        if settings.autoStartServer, !manager.isRunning, manager.problem == nil {
            manager.start()
        }
        dismissWindow(id: WindowID.onboarding)
    }
}

// MARK: - Step indicator

private struct StepIndicator: View {
    let current: ServerManager.OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ServerManager.OnboardingStep.allCases) { step in
                Capsule()
                    .fill(step.rawValue <= current.rawValue ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: step == current ? 24 : 8, height: 8)
                    .animation(.easeInOut(duration: 0.2), value: current)
            }
        }
        .accessibilityLabel("Step \(current.rawValue + 1) of \(ServerManager.OnboardingStep.allCases.count)")
    }
}
