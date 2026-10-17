import Foundation
import AppKit
import ApplicationServices
import CoreGraphics

/// Tracks the system permissions MacRemote needs and polls them so the UI can
/// react the moment the user grants access in System Settings.
@MainActor
final class PermissionsMonitor: ObservableObject {

    enum Permission: CaseIterable {
        case accessibility
        case screenRecording

        var isRequired: Bool { true }
    }

    @Published private(set) var accessibility = false
    @Published private(set) var screenRecording = false

    private var timer: Timer?

    init() {
        refresh()
        startPolling()
    }

    deinit {
        timer?.invalidate()
    }

    /// Every permission the app needs is granted.
    var allRequiredGranted: Bool { accessibility && screenRecording }

    func isGranted(_ permission: Permission) -> Bool {
        switch permission {
        case .accessibility: return accessibility
        case .screenRecording: return screenRecording
        }
    }

    // MARK: - Polling

    func startPolling(interval: TimeInterval = 1.0) {
        timer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let ax = AXIsProcessTrusted()
        if ax != accessibility {
            print("[Permissions] Accessibility: \(ax)")
            accessibility = ax
        }
        let screen = CGPreflightScreenCaptureAccess()
        if screen != screenRecording {
            print("[Permissions] Screen Recording: \(screen)")
            screenRecording = screen
        }
    }

    // MARK: - Requesting

    /// Shows the system prompt (first time only) and opens the Accessibility pane.
    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        Self.openSystemSettings(pane: .accessibility)
    }

    /// Shows the system prompt (first time only) and opens the Screen Recording pane.
    func requestScreenRecording() {
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        Self.openSystemSettings(pane: .screenRecording)
    }

    enum SettingsPane: String {
        case accessibility = "Privacy_Accessibility"
        case screenRecording = "Privacy_ScreenCapture"
        case localNetwork = "Privacy_LocalNetwork"
    }

    static func openSystemSettings(pane: SettingsPane) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") else { return }
        NSWorkspace.shared.open(url)
    }
}
