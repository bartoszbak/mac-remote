import SwiftUI

/// Shown on top of the connect sheet the first time this phone connects to a Mac.
/// The Mac pops up a window with a 6-digit code; typing it here finishes connecting.
struct PairingCodeView: View {
    @ObservedObject var client: NetworkClient
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    private var macName: String {
        client.connectingName ?? client.connectedServerName ?? String(localized: "pairing_this_mac")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 8)

                Image(systemName: "lock.laptopcomputer")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text(String(localized: "pairing_code_title \(macName)"))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(String(localized: "pairing_code_hint"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                codeField

                statusView
                    .frame(minHeight: 44)

                Spacer()
            }
            .padding(.bottom, 24)
            .navigationTitle(String(localized: "pairing_nav_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) {
                        client.disconnect()
                        dismiss()
                    }
                }
            }
            .onAppear { codeFocused = true }
            .onChange(of: code) { _, value in
                let digits = String(value.filter(\.isNumber).prefix(PairingCrypto.codeLength))
                if digits != value { code = digits }
                submitIfReady()
            }
            .onChange(of: client.pairingState) { _, _ in
                submitIfReady()
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(client.pairingState == .verifying)
    }

    /// Sends the code as soon as all six digits are in and the Mac is ready for it.
    private func submitIfReady() {
        guard code.count == PairingCrypto.codeLength, client.pairingState == .awaitingCode else { return }
        client.submitPairingCode(code)
    }

    private var isEditable: Bool {
        switch client.pairingState {
        case .requesting, .awaitingCode: return true
        default: return false
        }
    }

    private var codeField: some View {
        ZStack {
            // Invisible field drives the keyboard; the boxes below mirror it.
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($codeFocused)
                .disabled(!isEditable)
                .opacity(0.02)
                .frame(height: 1)

            HStack(spacing: 10) {
                ForEach(0..<PairingCrypto.codeLength, id: \.self) { index in
                    let digits = Array(code)
                    Text(index < digits.count ? String(digits[index]) : "")
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .frame(width: 44, height: 56)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(index == digits.count && codeFocused && isEditable ? Color.accentColor : Color.clear,
                                        lineWidth: 2)
                        )
                }
            }
            .opacity(isEditable || client.pairingState == .verifying ? 1 : 0.5)
            .contentShape(Rectangle())
            .onTapGesture { codeFocused = true }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch client.pairingState {
        case .idle, .awaitingCode:
            EmptyView()
        case .requesting:
            HStack(spacing: 8) {
                ProgressView()
                Text(String(localized: "pairing_requesting \(macName)"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .verifying:
            HStack(spacing: 8) {
                ProgressView()
                Text(String(localized: "pairing_in_progress"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .succeeded:
            Label(String(localized: "pairing_succeeded"), systemImage: "checkmark.circle.fill")
                .font(.footnote)
                .foregroundStyle(.green)
        case .failed(let reason):
            VStack(spacing: 12) {
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button(String(localized: "pairing_try_again")) {
                    code = ""
                    client.retryPairing()
                    codeFocused = true
                }
                .buttonStyle(.bordered)
            }
        }
    }
}

#Preview("Waiting for code") {
    Color.clear.sheet(isPresented: .constant(true)) {
        PairingCodeView(client: {
            let client = NetworkClient.preview(connected: false)
            client.setPreviewPairingState(.awaitingCode)
            return client
        }())
    }
}

#Preview("Wrong code") {
    Color.clear.sheet(isPresented: .constant(true)) {
        PairingCodeView(client: {
            let client = NetworkClient.preview(connected: false)
            client.setPreviewPairingState(.failed("Wrong code. Try again to get a new one."))
            return client
        }())
    }
}
