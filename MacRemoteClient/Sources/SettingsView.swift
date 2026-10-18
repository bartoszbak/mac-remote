import SwiftUI

/// UserDefaults keys and defaults for trackpad behaviour.
enum TrackpadSettings {
    static let sensitivityKey = "trackpad.sensitivity"
    static let tapToClickKey = "trackpad.tapToClick"
    static let naturalScrollingKey = "trackpad.naturalScrolling"
    static let hapticsKey = "trackpad.haptics"

    static let defaultSensitivity = 1.0
    static let sensitivityRange = 0.5...2.5
}

/// App settings sheet. Currently trackpad options plus a gesture cheat sheet.
struct SettingsView: View {
    @ObservedObject var client: NetworkClient

    @AppStorage(TrackpadSettings.sensitivityKey) private var sensitivity = TrackpadSettings.defaultSensitivity
    @AppStorage(TrackpadSettings.tapToClickKey) private var tapToClick = true
    @AppStorage(TrackpadSettings.naturalScrollingKey) private var naturalScrolling = true
    @AppStorage(TrackpadSettings.hapticsKey) private var hapticsEnabled = true
    @Environment(\.dismiss) private var dismiss
    @State private var showingPairing = false

    var body: some View {
        NavigationStack {
            Form {
                Section(String(localized: "trackpad_pointer_speed")) {
                    HStack {
                        Image(systemName: "tortoise.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(String(localized: "trackpad_pointer_speed_slow"))
                        Slider(value: $sensitivity, in: TrackpadSettings.sensitivityRange, step: 0.1)
                        Image(systemName: "hare.fill")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(String(localized: "trackpad_pointer_speed_fast"))
                    }
                }

                Section {
                    Toggle(isOn: $tapToClick) {
                        SettingsLabel(String(localized: "trackpad_tap_to_click"), systemImage: "pointer.arrow.ipad.rays")
                    }
                    Toggle(isOn: $naturalScrolling) {
                        SettingsLabel(String(localized: "trackpad_natural_scrolling"), systemImage: "arrow.up.and.down.text.horizontal")
                    }
                    Toggle(isOn: $hapticsEnabled) {
                        SettingsLabel(String(localized: "trackpad_haptics"), systemImage: "wave.3.right")
                    }
                }

                Section {
                    if client.isConnected {
                        HStack(spacing: 12) {
                            Image(systemName: client.isPaired ? "lock.fill" : "lock.open")
                                .foregroundStyle(.secondary)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.connectedServerName ?? String(localized: "pairing_this_mac"))
                                Text(client.isPaired
                                     ? (client.isSecure
                                        ? String(localized: "settings_mac_paired_encrypted")
                                        : String(localized: "settings_mac_paired"))
                                     : String(localized: "settings_mac_not_paired"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if client.isPaired {
                            Button(String(localized: "unlock_forget_pairing"), role: .destructive) {
                                client.forgetPairing()
                            }
                        } else {
                            Button {
                                showingPairing = true
                            } label: {
                                SettingsLabel(String(localized: "settings_pair_button"), systemImage: "link")
                            }
                        }
                    } else {
                        Text(String(localized: "settings_mac_disconnected"))
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(String(localized: "settings_section_mac"))
                } footer: {
                    Text(client.isPaired
                         ? String(localized: "settings_mac_paired_footer")
                         : String(localized: "settings_mac_unpaired_footer"))
                }

                Section(String(localized: "trackpad_gestures_header")) {
                    GestureRow(icon: "pointer.arrow.ipad",
                               title: String(localized: "trackpad_gesture_move"),
                               detail: String(localized: "trackpad_gesture_move_how"))
                    GestureRow(icon: "hand.tap.fill",
                               title: String(localized: "trackpad_gesture_click"),
                               detail: String(localized: "trackpad_gesture_click_how"))
                    GestureRow(icon: "hand.tap.fill",
                               title: String(localized: "trackpad_gesture_double_click"),
                               detail: String(localized: "trackpad_gesture_double_click_how"))
                    GestureRow(icon: "hand.draw.fill",
                               title: String(localized: "trackpad_gesture_drag"),
                               detail: String(localized: "trackpad_gesture_drag_how"))
                    GestureRow(icon: "arrow.up.and.down",
                               title: String(localized: "trackpad_gesture_scroll"),
                               detail: String(localized: "trackpad_gesture_scroll_how"))
                    GestureRow(icon: "contextualmenu.and.cursorarrow",
                               title: String(localized: "trackpad_gesture_right_click"),
                               detail: String(localized: "trackpad_gesture_right_click_how"))
                    GestureRow(icon: "arrow.up.left.and.arrow.down.right",
                               title: String(localized: "trackpad_gesture_zoom"),
                               detail: String(localized: "trackpad_gesture_zoom_how"))
                }
            }
            .sheet(isPresented: $showingPairing) {
                PairingSheet(client: client)
            }
            .softTopEdge()
            .navigationTitle(String(localized: "settings"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "done")) {
                        dismiss()
                    }
                }
            }
        }
    }
}

/// Toggle label with a grey icon, matching the gesture rows.
struct SettingsLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
        }
    }
}

/// One line of the gesture cheat sheet.
struct GestureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Settings, paired") {
    SettingsView(client: .preview(unlockPaired: true))
}

#Preview("Settings, not paired") {
    SettingsView(client: .preview())
}

#Preview("Settings label") {
    Form {
        Toggle(isOn: .constant(true)) {
            SettingsLabel("Tap to Click", systemImage: "pointer.arrow.ipad.rays")
        }
    }
}

#Preview("Gesture row") {
    List {
        GestureRow(icon: "hand.tap.fill", title: "Click", detail: "Tap with one finger")
    }
}
