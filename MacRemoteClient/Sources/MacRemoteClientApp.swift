import SwiftUI

@main
struct MacRemoteClientApp: App {
    @StateObject private var browser = BonjourBrowser()
    @StateObject private var client = NetworkClient()
    @State private var showConnectionSheet = false
    @State private var showSettings = false
    /// Remembered between launches.
    @AppStorage("selectedTab") private var selectedTab: RemoteTab = .trackpad

    /// Debug builds launched with `-skipConnectSheet` start without the connect sheet,
    /// so layouts can be screenshotted in the simulator.
    private static var skipConnectSheetForScreenshots: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-skipConnectSheet")
        #else
        false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                RemoteControlView(client: client, selectedTab: $selectedTab)
                    .softTopEdge()
                    .navigationTitle(selectedTab.title)
                    .navigationBarTitleDisplayMode(.inline)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        RemoteTabBar(selection: $selectedTab)
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
                SettingsView(client: client)
            }
            .onAppear {
                #if DEBUG
                // `-fakeConnected` makes screens render as if a Mac were connected, for screenshots.
                if ProcessInfo.processInfo.arguments.contains("-fakeConnected") {
                    client.isConnected = true
                    client.connectedServerName = "BakBook"
                }
                #endif
                if !client.isConnected, !Self.skipConnectSheetForScreenshots {
                    showConnectionSheet = true
                }
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

#Preview("Status buttons") {
    HStack(spacing: 32) {
        ConnectionStatusButton(isConnected: true) {}
        ConnectionStatusButton(isConnected: false) {}
    }
    .font(.title2)
    .padding()
}
