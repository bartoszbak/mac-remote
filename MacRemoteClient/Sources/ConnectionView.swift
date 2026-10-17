import SwiftUI

/// Bottom sheet listing Macs found on the local network as an inset-grouped table under
/// a native inline title bar. The sheet's height is sized to the table.
struct ConnectionView: View {
    @ObservedObject var browser: BonjourBrowser
    @ObservedObject var client: NetworkClient
    @Environment(\.dismiss) private var dismiss

    // Layout metrics used to size the sheet to its table content.
    private let navigationBarHeight: CGFloat = 56
    private let tableTopInset: CGFloat = 20
    private let tableBottomInset: CGFloat = 24
    private let sectionHeaderHeight: CGFloat = 36
    private let rowHeight: CGFloat = 64
    private let maxSheetHeight: CGFloat = 560

    var body: some View {
        NavigationStack {
            List {
                if client.isConnected {
                    Section(String(localized: "connection_current")) {
                        HStack(spacing: 14) {
                            ServerGlyph()
                            VStack(alignment: .leading, spacing: 2) {
                                Text(client.connectedServerName ?? String(localized: "connection_status_connected"))
                                Text(String(localized: "connection_status_connected"))
                                    .font(.footnote)
                                    .foregroundStyle(.green)
                            }
                            Spacer()
                            Button(String(localized: "connection_disconnect")) {
                                client.disconnect()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.white)
                        }
                    }
                }

                if !client.isConnected || !otherServers.isEmpty {
                    Section(client.isConnected
                            ? String(localized: "connection_other_available")
                            : String(localized: "connection_available")) {
                        if otherServers.isEmpty {
                            emptyRow
                        } else {
                            ForEach(otherServers) { server in
                                ServerRow(name: server.name, state: .available) {
                                    client.connect(to: server.endpoint, name: server.name)
                                    dismiss()
                                }
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(String(localized: "connection_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        browser.startBrowsing()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(String(localized: "connection_refresh"))
                }
            }
        }
        .presentationDetents([.height(min(estimatedHeight, maxSheetHeight)), .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            browser.startBrowsing()
        }
        .onDisappear {
            browser.stopBrowsing()
        }
    }

    /// Discovered Macs other than the one we are connected to.
    private var otherServers: [BonjourBrowser.DiscoveredServer] {
        guard client.isConnected, let current = client.connectedServerName else { return browser.servers }
        return browser.servers.filter { $0.name != current }
    }

    /// Height of the sheet so the table shows without scrolling.
    private var estimatedHeight: CGFloat {
        var sections: CGFloat = 0
        var rows: CGFloat = 0
        if client.isConnected {
            sections += 1
            rows += 1
        }
        if !client.isConnected || !otherServers.isEmpty {
            sections += 1
            rows += CGFloat(max(otherServers.count, 1))
        }
        return navigationBarHeight + tableTopInset + tableBottomInset
            + sections * sectionHeaderHeight + rows * rowHeight
    }

    private var emptyRow: some View {
        HStack(spacing: 14) {
            if browser.isSearching {
                ProgressView()
                    .frame(width: 40, height: 40)
                Text(String(localized: "connection_searching"))
                    .foregroundStyle(.secondary)
            } else {
                ServerGlyph(systemImage: "antenna.radiowaves.left.and.right.slash")
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(localized: "connection_none_title"))
                    Text(String(localized: "connection_none_message"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Antenna in a light grey circle, the glyph for a Mac in the list.
struct ServerGlyph: View {
    var systemImage = "antenna.radiowaves.left.and.right"

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.medium))
            .foregroundStyle(.secondary)
            .frame(width: 40, height: 40)
            .background(Color(.systemGray5), in: Circle())
    }
}

/// One Mac in the list.
struct ServerRow: View {
    enum State { case available, connected }

    let name: String
    let state: State
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ServerGlyph()
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(state == .connected
                         ? String(localized: "connection_status_connected")
                         : String(localized: "connection_tap_to_connect"))
                        .font(.footnote)
                        .foregroundStyle(state == .connected ? Color.green : Color.secondary)
                }
                Spacer()
                if state == .available {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Previews

#Preview("Macs found") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ConnectionView(browser: .preview(), client: .preview(connected: false))
        }
}

#Preview("Connected") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ConnectionView(browser: .preview(), client: .preview())
        }
}

#Preview("Searching") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ConnectionView(browser: .preview(serverNames: [], searching: true), client: .preview(connected: false))
        }
}

#Preview("No Macs") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            ConnectionView(browser: .preview(serverNames: []), client: .preview(connected: false))
        }
}

#Preview("Server rows") {
    List {
        ServerRow(name: "Studio Mac", state: .connected) {}
        ServerRow(name: "MacBook Pro", state: .available) {}
    }
    .listStyle(.insetGrouped)
}
