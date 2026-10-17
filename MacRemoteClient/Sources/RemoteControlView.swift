import SwiftUI

/// The sections of the remote, chosen from the title menu in the toolbar.
enum RemoteTab: String, CaseIterable, Identifiable {
    case trackpad, screen, media, keyboard, apps, system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .trackpad: return String(localized: "tab_trackpad")
        case .screen: return String(localized: "tab_screen")
        case .media: return String(localized: "tab_media")
        case .keyboard: return String(localized: "tab_keyboard")
        case .apps: return String(localized: "tab_apps")
        case .system: return String(localized: "tab_system")
        }
    }

    var systemImage: String {
        switch self {
        case .trackpad: return "hand.point.up.left"
        case .screen: return "display"
        case .media: return "speaker.wave.2"
        case .keyboard: return "keyboard"
        case .apps: return "square.grid.2x2"
        case .system: return "lock"
        }
    }
}

/// Main remote control interface. Shows the selected section; the section picker lives in
/// the navigation title's dropdown menu, see `MacRemoteClientApp`.
struct RemoteControlView: View {
    @ObservedObject var client: NetworkClient
    @Binding var selectedTab: RemoteTab

    var body: some View {
        // Deliberately not a paging TabView: page swiping would steal horizontal
        // finger movement from the trackpad.
        Group {
            switch selectedTab {
            case .trackpad: trackpadTab
            case .screen: screenTab
            case .media: mediaTab
            case .keyboard: keyboardTab
            case .apps: appsTab
            case .system: systemTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Screen Tab

    private var screenTab: some View {
        ScreenView(client: client)
    }

    // MARK: - Apps Tab

    private var appsTab: some View {
        AppsView(client: client)
    }

    // MARK: - Trackpad Tab

    private var trackpadTab: some View {
        TrackpadView(client: client)
    }

    // MARK: - Media Tab

    private var mediaTab: some View {
        VStack(spacing: 24) {
            Spacer()

            // Volume controls
            HStack(spacing: 40) {
                MediaButton(icon: "speaker.minus.fill", label: "Vol -") {
                    client.volumeDown()
                }

                MediaButton(icon: "speaker.slash.fill", label: "Mute") {
                    client.mute()
                }

                MediaButton(icon: "speaker.plus.fill", label: "Vol +") {
                    client.volumeUp()
                }
            }

            Divider()
                .padding(.horizontal, 40)

            // Playback controls
            HStack(spacing: 40) {
                MediaButton(icon: "backward.fill", label: "Previous") {
                    client.previousTrack()
                }

                MediaButton(icon: "playpause.fill", label: "Play/Pause", large: true) {
                    client.playPause()
                }

                MediaButton(icon: "forward.fill", label: "Next") {
                    client.nextTrack()
                }
            }

            Divider()
                .padding(.horizontal, 40)

            // Brightness controls
            HStack(spacing: 40) {
                MediaButton(icon: "sun.min.fill", label: "Bright -") {
                    client.brightnessDown()
                }

                MediaButton(icon: "sun.max.fill", label: "Bright +") {
                    client.brightnessUp()
                }
            }

            Spacer()
        }
        .padding()
    }

    // MARK: - Keyboard Tab

    private var keyboardTab: some View {
        RemoteKeyboardView(client: client)
    }

    // MARK: - System Tab

    private var systemTab: some View {
        SystemView(client: client)
    }
}

// MARK: - Media Button

struct MediaButton: View {
    let icon: String
    let label: String
    var large: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(large ? .largeTitle : .title2)
                Text(label)
                    .font(.caption)
            }
            .frame(width: large ? 90 : 70, height: large ? 90 : 70)
            .background(Color(.systemGray5))
            .cornerRadius(large ? 45 : 16)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("Remote control") {
    struct Host: View {
        @State private var tab: RemoteTab = .media
        var body: some View {
            NavigationStack {
                RemoteControlView(client: .preview(), selectedTab: $tab)
                    .navigationTitle(tab.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarTitleMenu { RemoteTabMenu(selectedTab: $tab) }
            }
        }
    }
    return Host()
}

#Preview("Media button") {
    HStack(spacing: 16) {
        MediaButton(icon: "backward.fill", label: "Previous") {}
        MediaButton(icon: "playpause.fill", label: "Play/Pause", large: true) {}
        MediaButton(icon: "forward.fill", label: "Next") {}
    }
    .padding()
}
