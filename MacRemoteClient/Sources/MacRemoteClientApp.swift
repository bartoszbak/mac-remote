import SwiftUI

@main
struct MacRemoteClientApp: App {
    @StateObject private var browser = BonjourBrowser()
    @StateObject private var client = NetworkClient()
    @State private var showConnectionSheet = false
    @State private var showSettings = false
    @State private var selectedTab: RemoteTab = .trackpad

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RemoteControlView(client: client, selectedTab: $selectedTab)
                    .softTopEdge()
                    .navigationTitle(selectedTab.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarTitleMenu {
                        RemoteTabMenu(selectedTab: $selectedTab)
                    }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            ConnectionStatusButton(isConnected: client.isConnected) {
                                showConnectionSheet = true
                            }
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                showSettings = true
                            } label: {
                                Image(systemName: "ellipsis")
                            }
                            .accessibilityLabel(String(localized: "settings"))
                        }
                    }
            }
            .sheet(isPresented: $showConnectionSheet) {
                ConnectionView(browser: browser, client: client)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .onAppear {
                if !client.isConnected {
                    showConnectionSheet = true
                }
            }
        }
    }
}

/// Contents of the navigation title's dropdown: one checkmarked entry per section.
struct RemoteTabMenu: View {
    @Binding var selectedTab: RemoteTab

    var body: some View {
        Picker(String(localized: "tab_menu"), selection: $selectedTab) {
            ForEach(RemoteTab.allCases) { tab in
                Label(tab.title, systemImage: tab.systemImage).tag(tab)
            }
        }
    }
}

/// Toolbar status icon: a bolt, green when connected and greyed out when not.
struct ConnectionStatusButton: View {
    let isConnected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "bolt.horizontal.fill")
                .foregroundStyle(isConnected ? Color.green : Color.secondary)
                .contentTransition(.symbolEffect(.replace))
        }
        .accessibilityLabel(isConnected
                            ? String(localized: "connection_status_connected")
                            : String(localized: "connection_status_disconnected"))
    }
}

#Preview("Section menu") {
    struct Host: View {
        @State private var tab: RemoteTab = .trackpad
        var body: some View {
            NavigationStack {
                Text(tab.title)
                    .navigationTitle(tab.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbarTitleMenu { RemoteTabMenu(selectedTab: $tab) }
            }
        }
    }
    return Host()
}

#Preview("Status buttons") {
    HStack(spacing: 32) {
        ConnectionStatusButton(isConnected: true) {}
        ConnectionStatusButton(isConnected: false) {}
    }
    .font(.title2)
    .padding()
}
