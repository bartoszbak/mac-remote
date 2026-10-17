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
    @AppStorage(TrackpadSettings.sensitivityKey) private var sensitivity = TrackpadSettings.defaultSensitivity
    @AppStorage(TrackpadSettings.tapToClickKey) private var tapToClick = true
    @AppStorage(TrackpadSettings.naturalScrollingKey) private var naturalScrolling = true
    @AppStorage(TrackpadSettings.hapticsKey) private var hapticsEnabled = true
    @Environment(\.dismiss) private var dismiss

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
                    Toggle(String(localized: "trackpad_tap_to_click"), isOn: $tapToClick)
                    Toggle(String(localized: "trackpad_natural_scrolling"), isOn: $naturalScrolling)
                    Toggle(String(localized: "trackpad_haptics"), isOn: $hapticsEnabled)
                } footer: {
                    Text(String(localized: "trackpad_natural_scrolling_footer"))
                }

                Section(String(localized: "trackpad_gestures_header")) {
                    GestureRow(icon: "hand.point.up.left.fill",
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

/// One line of the gesture cheat sheet.
struct GestureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.blue)
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

#Preview("Settings") {
    SettingsView()
}

#Preview("Gesture row") {
    List {
        GestureRow(icon: "hand.tap.fill", title: "Click", detail: "Tap with one finger")
    }
}
