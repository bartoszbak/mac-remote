import SwiftUI

/// Enter the 6-digit code shown on the Mac. Lives in Settings; the System section
/// only points here.
struct PairingSheet: View {
    @ObservedObject var client: NetworkClient
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""
    @FocusState private var codeFocused: Bool

    private var macName: String {
        client.connectedServerName ?? String(localized: "pairing_this_mac")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer(minLength: 8)

                Image(systemName: "lock.laptopcomputer")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Text(String(localized: "pairing_title \(macName)"))
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(String(localized: "pairing_instructions"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal)

                codeField

                statusView

                Spacer()

                Button {
                    client.pair(code: code)
                } label: {
                    Text(String(localized: "pairing_pair_button"))
                        .frame(maxWidth: .infinity)
                }
                .prominentGlassButton()
                .controlSize(.large)
                .disabled(code.count != PairingCrypto.codeLength || client.pairingState == .inProgress || !client.isConnected)
                .padding(.horizontal)
            }
            .padding(.bottom, 24)
            .navigationTitle(String(localized: "pairing_nav_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "cancel")) { dismiss() }
                }
            }
            .onAppear {
                client.resetPairingState()
                codeFocused = true
            }
            .onChange(of: client.pairingState) { _, state in
                if state == .succeeded {
                    Task {
                        try? await Task.sleep(for: .seconds(1.2))
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var codeField: some View {
        ZStack {
            // Invisible field drives the keyboard; the boxes below mirror it.
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($codeFocused)
                .opacity(0.02)
                .frame(height: 1)
                .onChange(of: code) { _, value in
                    let digits = value.filter(\.isNumber)
                    code = String(digits.prefix(PairingCrypto.codeLength))
                }

            HStack(spacing: 10) {
                ForEach(0..<PairingCrypto.codeLength, id: \.self) { index in
                    let digits = Array(code)
                    Text(index < digits.count ? String(digits[index]) : "")
                        .font(.system(size: 28, weight: .medium, design: .rounded))
                        .frame(width: 44, height: 56)
                        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(index == digits.count && codeFocused ? Color.accentColor : Color.clear, lineWidth: 2)
                        )
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { codeFocused = true }
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch client.pairingState {
        case .idle:
            if !client.isConnected {
                Text(String(localized: "pairing_not_connected"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .inProgress:
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
            Text(reason)
                .font(.footnote)
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}

#Preview("Pairing") {
    Color.clear.sheet(isPresented: .constant(true)) {
        PairingSheet(client: .preview())
    }
}
