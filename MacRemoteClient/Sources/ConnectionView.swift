import SwiftUI

/// Bottom sheet listing Macs found on the local network as an inset-grouped table under
/// a native inline title bar. The sheet's height is sized to the table.
struct ConnectionView: View {
    @ObservedObject var browser: BonjourBrowser
    @ObservedObject var client: NetworkClient
    @ObservedObject private var knownMacs: KnownMacStore
    @Environment(\.dismiss) private var dismiss

    /// Macs woken from this sheet, so the row can say so and the automatic wake fires once.
    @State private var wakingMacs: Set<String> = []
    @State private var didAutoWake = false

    init(browser: BonjourBrowser, client: NetworkClient) {
        self.browser = browser
        self.client = client
        _knownMacs = ObservedObject(wrappedValue: client.knownMacs)
    }

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
                    Section {
                        if otherServers.isEmpty {
                            emptyRow
                        } else {
                            ForEach(otherServers) { server in
                                ServerRow(name: server.name,
                                          state: client.isConnecting && client.connectingName == server.name ? .connecting : .available) {
                                    client.connect(to: server.endpoint, name: server.name)
                                }
                                .disabled(client.isConnecting)
                            }
                        }
                    } header: {
                        Text(client.isConnected
                             ? String(localized: "connection_other_available")
                             : String(localized: "connection_available"))
                    } footer: {
                        if let error = client.connectionError, !client.isConnecting, !client.isConnected {
                            Text(error)
                        }
                    }
                }

                if !sleepingMacs.isEmpty {
                    Section(String(localized: "connection_known_section")) {
                        ForEach(sleepingMacs) { mac in
                            SleepingMacRow(mac: mac, isWaking: wakingMacs.contains(mac.name)) {
                                wake(mac)
                            }
                            .swipeActions {
                                Button(String(localized: "connection_forget"), role: .destructive) {
                                    knownMacs.forget(name: mac.name)
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
        .sheet(isPresented: pairingSheetBinding) {
            PairingCodeView(client: client)
        }
        .onChange(of: client.isConnected) { wasConnected, isConnected in
            // Close once the encrypted link is up, after the success tick if pairing ran.
            guard isConnected, !wasConnected else { return }
            let delay: Double = client.pairingState == .succeeded ? 1.2 : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { dismiss() }
        }
        .onAppear {
            browser.startBrowsing()
        }
        .onDisappear {
            browser.stopBrowsing()
        }
        .task {
            // The Mac takes a moment to be discovered; if the one used last is still missing
            // after that, send a wake once. Browsing continues so it shows up when awake.
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, !didAutoWake, !client.isConnected,
                  let mac = knownMacs.byRecency.first, mac.canWake,
                  !browser.servers.contains(where: { $0.name == mac.name }) else { return }
            didAutoWake = true
            wake(mac)
        }
    }

    /// The code sheet is up whenever a pairing is in progress. Swiping it away cancels.
    private var pairingSheetBinding: Binding<Bool> {
        Binding(
            get: { client.pairingState != .idle },
            set: { presented in
                if !presented, !client.isConnected { client.disconnect() }
            }
        )
    }

    /// Known Macs that are neither discovered nor connected right now.
    private var sleepingMacs: [KnownMac] {
        let visible = Set(browser.servers.map(\.name))
        return knownMacs.byRecency.filter { $0.name != client.connectedServerName && !visible.contains($0.name) }
    }

    private func wake(_ mac: KnownMac) {
        guard WakeOnLANSender.wake(mac) else { return }
        wakingMacs.insert(mac.name)
        browser.startBrowsing()
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
        if !sleepingMacs.isEmpty {
            sections += 1
            rows += CGFloat(sleepingMacs.count)
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
    enum State { case available, connecting, connected }

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
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(state == .connected ? Color.green : Color.secondary)
                }
                Spacer()
                switch state {
                case .available:
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color(.tertiaryLabel))
                case .connecting:
                    ProgressView()
                case .connected:
                    EmptyView()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var subtitle: String {
        switch state {
        case .available: return String(localized: "connection_tap_to_connect")
        case .connecting: return String(localized: "connection_connecting")
        case .connected: return String(localized: "connection_status_connected")
        }
    }
}

/// A Mac seen before that is not on the network right now, with a Wake button when the
/// Mac allows waking.
struct SleepingMacRow: View {
    let mac: KnownMac
    let isWaking: Bool
    let onWake: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ServerGlyph(systemImage: "moon.zzz")
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.name)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if mac.canWake {
                Button(String(localized: "connection_wake"), action: onWake)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(.white)
                    .disabled(isWaking)
            }
        }
    }

    private var subtitle: String {
        if isWaking { return String(localized: "connection_waking") }
        if !mac.canWake { return String(localized: "connection_wake_disabled") }
        return String(localized: "connection_not_found")
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

#Preview("Sleeping Macs") {
    List {
        SleepingMacRow(mac: KnownMacStore.preview().byRecency[0], isWaking: false) {}
        SleepingMacRow(mac: KnownMacStore.preview().byRecency[0], isWaking: true) {}
        SleepingMacRow(mac: KnownMacStore.preview().byRecency[1], isWaking: false) {}
    }
    .listStyle(.insetGrouped)
}

#Preview("Server rows") {
    List {
        ServerRow(name: "Studio Mac", state: .connected) {}
        ServerRow(name: "MacBook Pro", state: .available) {}
        ServerRow(name: "Office iMac", state: .connecting) {}
    }
    .listStyle(.insetGrouped)
}
