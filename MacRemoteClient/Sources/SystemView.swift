import SwiftUI

/// System section: remote unlock and lock, as a native inset-grouped list.
struct SystemView: View {
    @ObservedObject var client: NetworkClient

    @State private var showingLockConfirmation = false
    @State private var pairingKey = ""
    @State private var pairingKeyError = false

    var body: some View {
        List {
            unlockSection
            lockSection
        }
        .listStyle(.insetGrouped)
        .softTopEdge()
        .confirmationDialog(
            String(localized: "lock_screen_confirmation_title"),
            isPresented: $showingLockConfirmation,
            titleVisibility: .visible
        ) {
            Button(String(localized: "lock_screen_confirm"), role: .destructive) {
                client.lockScreen()
            }
            Button(String(localized: "cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "lock_screen_confirmation_message"))
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var unlockSection: some View {
        Section {
            if client.hasUnlockPairingKey {
                if client.isScreenLocked == false {
                    Label {
                        Text(String(localized: "unlock_state_unlocked"))
                    } icon: {
                        Image(systemName: "lock.open.fill")
                            .foregroundStyle(.green)
                    }
                } else {
                    Button {
                        client.requestUnlock()
                    } label: {
                        Text(client.isAuthenticatingForUnlock
                             ? String(localized: "unlock_authenticating")
                             : String(localized: "unlock_mac"))
                            .frame(maxWidth: .infinity)
                    }
                    .prominentGlassButton()
                    .controlSize(.large)
                    .disabled(!client.isUnlockAvailable || client.isAuthenticatingForUnlock)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    .listRowBackground(Color.clear)
                }
            } else {
                TextField(String(localized: "unlock_pairing_key"), text: $pairingKey)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))

                Button(String(localized: "unlock_save_pairing")) {
                    pairingKeyError = !client.saveUnlockPairingKey(pairingKey)
                    if !pairingKeyError {
                        pairingKey = ""
                    }
                }
                .disabled(pairingKey.isEmpty)
            }
        } header: {
            Text(String(localized: "system_section_unlock"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if pairingKeyError {
                    Text(String(localized: "unlock_invalid_pairing_key"))
                        .foregroundStyle(.red)
                }
                if let status = client.unlockStatus {
                    Text(status)
                }
                if !client.hasUnlockPairingKey {
                    Text(String(localized: "system_unlock_footer"))
                }
            }
        }
    }

    private var lockSection: some View {
        Section {
            Button {
                showingLockConfirmation = true
            } label: {
                Label(String(localized: "lock_screen"), systemImage: "lock.fill")
            }
            .disabled(!client.isConnected)
        } header: {
            Text(String(localized: "system_section_lock"))
        } footer: {
            Text(String(localized: "system_lock_footer"))
        }
    }
}

// MARK: - Previews

#Preview("Paired, Mac locked") {
    NavigationStack {
        SystemView(client: .preview(unlockPaired: true, screenLocked: true))
            .navigationTitle("System")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Paired, Mac unlocked") {
    NavigationStack {
        SystemView(client: .preview(unlockPaired: true, screenLocked: false))
            .navigationTitle("System")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Not paired") {
    NavigationStack {
        SystemView(client: .preview(unlockPaired: false))
            .navigationTitle("System")
            .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview("Disconnected") {
    NavigationStack {
        SystemView(client: .preview(connected: false))
            .navigationTitle("System")
            .navigationBarTitleDisplayMode(.inline)
    }
}
