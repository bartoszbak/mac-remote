import Foundation
import CryptoKit
import LocalAuthentication
import Network

/// TCP Client that connects to a MacRemote server
final class NetworkClient: ObservableObject {

    @Published var isConnected = false
    /// Display name of the Mac the current connection was made to.
    @Published var connectedServerName: String?
    @Published var screenSize: CGSize = .zero
    @Published var connectionError: String?
    @Published var apps: [AppInfo] = []
    @Published var isLoadingApps = false
    @Published var isScreenStreaming = false
    @Published private(set) var isUnlockAvailable = false
    /// Whether the Mac's screen is locked, once the server has reported it.
    @Published private(set) var isScreenLocked: Bool?
    @Published var unlockStatus: String?
    @Published var isAuthenticatingForUnlock = false

    // MARK: Pairing and encryption state

    /// Stable ID of the connected Mac, from its `welcome`.
    @Published private(set) var serverID: String?
    /// Whether this phone holds a pairing key for the connected Mac.
    @Published private(set) var isPaired = false
    /// Whether the current connection is TLS.
    @Published private(set) var isSecure = false
    /// False when the Mac only accepts paired devices and this one is not paired yet.
    @Published private(set) var controlAllowed = true
    @Published private(set) var pairingState: PairingState = .idle
    /// A connection attempt is under way (before the encrypted link is up).
    @Published private(set) var isConnecting = false
    /// Name of the Mac being connected to while `isConnecting`.
    @Published private(set) var connectingName: String?

    /// Connecting to an unpaired Mac runs this sequence; `isConnected` only becomes true
    /// once pairing succeeds and the encrypted link is up.
    enum PairingState: Equatable {
        case idle
        /// Asked the Mac to pair; it is about to show a code.
        case requesting
        /// The Mac shows a code; waiting for the user to type it.
        case awaitingCode
        case verifying
        case succeeded
        case failed(String)
    }

    /// Macs seen before, with the details needed to wake them.
    let knownMacs: KnownMacStore
    /// Macs this phone has paired with.
    let pairedMacs: PairedMacStore

    // Callback for received screen frames
    var onScreenFrameReceived: ((ScreenFrame) -> Void)?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.macremote.client", qos: .userInteractive)
    private var unlockChallenge: Data?
    private var tlsPort: UInt16?
    private var pairingPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    private var pairingCode: String?
    private var pendingPairing: (sessionKey: SymmetricKey, presharedKey: SymmetricKey)?
    /// Retries while the Mac's encrypted listener is still coming up after pairing.
    private var upgradeAttempts = 0

    init(knownMacs: KnownMacStore = KnownMacStore(), pairedMacs: PairedMacStore = PairedMacStore()) {
        self.knownMacs = knownMacs
        self.pairedMacs = pairedMacs
    }

#if DEBUG
    /// Preview-only: fake pairing and unlock state without touching the Keychain.
    func setPreviewUnlockState(paired: Bool, available: Bool, locked: Bool? = nil) {
        isPaired = paired
        isSecure = paired
        isUnlockAvailable = available
        isScreenLocked = locked
        serverID = "preview-mac"
    }

    /// Preview-only: show the code-entry flow in a given state.
    func setPreviewPairingState(_ state: PairingState, macName: String = "Studio Mac") {
        pairingState = state
        isConnecting = true
        connectingName = macName
        connectedServerName = macName
    }
#endif

    // MARK: - Connection

    /// Connects in plaintext first. That link can only identify this phone and pair; the
    /// Mac's `welcome` says where its encrypted port is. If this phone is paired with that
    /// Mac it upgrades to TLS straight away, otherwise pairing starts automatically.
    /// `isConnected` becomes true only once the encrypted link is up.
    func connect(to endpoint: NWEndpoint, name: String? = nil) {
        disconnect()
        connectedServerName = name
        connectingName = name
        isConnecting = true
        let connection = NWConnection(to: endpoint, using: Self.parameters(tls: nil))
        self.connection = connection
        attach(connection, secure: false)
        connection.start(queue: queue)
    }

    /// Pointer moves are tiny packets sent every frame. Nagle's algorithm would hold
    /// each one until the previous is acknowledged, which reads as a stuttering cursor.
    private static func parameters(tls: NWProtocolTLS.Options?) -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.serviceClass = .responsiveData
        return parameters
    }

    private func attach(_ connection: NWConnection, secure: Bool) {
        connection.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                guard let self, connection === self.connection || connection === self.pendingSecure else { return }
                switch state {
                case .ready:
                    if secure {
                        self.finishUpgrade(to: connection)
                    } else {
                        self.connectionError = nil
                    }
                    self.startReceiving(on: connection)
                    self.send(.hello(deviceID: DeviceIdentity.id, deviceName: DeviceIdentity.name,
                                     protocolVersion: NetworkConstants.protocolVersion), on: connection)
                    print("[Client] Link up (\(secure ? "TLS" : "plaintext"))")

                case .waiting(let error) where secure, .failed(let error) where secure:
                    self.handleUpgradeProblem(error)

                case .failed(let error):
                    self.isConnected = false
                    self.isConnecting = false
                    self.connectionError = error.localizedDescription
                    print("[Client] Failed: \(error)")

                case .cancelled:
                    if !secure, connection === self.connection {
                        self.isConnected = false
                        self.isConnecting = false
                    }

                default:
                    break
                }
            }
        }
    }

    func disconnect() {
        pendingSecure?.cancel()
        pendingSecure = nil
        connection?.cancel()
        connection = nil
        isConnected = false
        isSecure = false
        isPaired = false
        controlAllowed = true
        serverID = nil
        tlsPort = nil
        connectedServerName = nil
        isScreenLocked = nil
        isConnecting = false
        connectingName = nil
        pairingState = .idle
        pairingPrivateKey = nil
        pairingCode = nil
        pendingPairing = nil
        upgradeAttempts = 0
    }

    // MARK: - TLS upgrade

    private var pendingSecure: NWConnection?

    /// Opens a TLS-PSK connection to the Mac's encrypted port using the stored pairing key.
    private func upgradeToTLS(serverID: String, port: UInt16) {
        guard pendingSecure == nil, !isSecure,
              let key = pairedMacs.presharedKey(for: serverID),
              let plain = connection,
              case .hostPort(let host, _)? = plain.currentPath?.remoteEndpoint else { return }

        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(DeviceIdentity.id.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(security, keyData as __DispatchData, identity as __DispatchData)
        if let suite = tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256)) {
            sec_protocol_options_append_tls_ciphersuite(security, suite)
        }
        sec_protocol_options_set_min_tls_protocol_version(security, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .TLSv12)

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let secure = NWConnection(host: host, port: nwPort, using: Self.parameters(tls: tls))
        pendingSecure = secure
        attach(secure, secure: true)
        secure.start(queue: queue)
        print("[Client] Upgrading to TLS on port \(port)")
    }

    private func finishUpgrade(to secure: NWConnection) {
        let plain = connection
        connection = secure
        pendingSecure = nil
        plain?.stateUpdateHandler = nil
        plain?.cancel()
        isSecure = true
        isPaired = true
        isConnected = true
        isConnecting = false
        upgradeAttempts = 0
        connectionError = nil
        if pairingState == .succeeded {
            // Let the success state show briefly before the sheet goes away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                if self?.pairingState == .succeeded { self?.pairingState = .idle }
            }
        } else {
            pairingState = .idle
        }
    }

    /// The encrypted link did not come up. Right after pairing the Mac's listener may still
    /// be starting (connection refused): retry briefly. A TLS failure means the Mac no
    /// longer has this phone's key: forget it and pair again over the open plaintext link.
    private func handleUpgradeProblem(_ error: NWError) {
        pendingSecure?.stateUpdateHandler = nil
        pendingSecure?.cancel()
        pendingSecure = nil

        if case .tls = error {
            print("[Client] TLS rejected: \(error)")
            if let serverID { pairedMacs.forget(serverID: serverID) }
            isPaired = false
            beginPairing()
            return
        }

        upgradeAttempts += 1
        guard upgradeAttempts <= 15, let serverID, let tlsPort else {
            isConnecting = false
            pairingState = .idle
            connectionError = error.localizedDescription
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.isConnecting, !self.isSecure else { return }
            self.upgradeToTLS(serverID: serverID, port: tlsPort)
        }
    }

    // MARK: - Pairing

    /// Asks the Mac to pair. The Mac opens a window with a 6-digit code.
    private func beginPairing() {
        guard let connection, !isSecure else { return }
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        pairingPrivateKey = privateKey
        pairingCode = nil
        pendingPairing = nil
        pairingState = .requesting
        send(.pairRequest(deviceID: DeviceIdentity.id, deviceName: DeviceIdentity.name,
                          publicKey: privateKey.publicKey.rawRepresentation), on: connection)
    }

    /// Sends proof of the code shown on the Mac.
    func submitPairingCode(_ code: String) {
        guard pairingState == .awaitingCode, let pending = pendingPairing, let connection else { return }
        guard let normalized = PairingCrypto.normalizedCode(code) else {
            pairingState = .failed(String(localized: "pairing_invalid_code"))
            return
        }
        pairingCode = normalized
        pairingState = .verifying
        send(.pairConfirm(proof: PairingCrypto.clientProof(sessionKey: pending.sessionKey, code: normalized)), on: connection)
    }

    /// Requests a fresh code after a wrong or expired one.
    func retryPairing() {
        beginPairing()
    }

    /// Forgets this Mac and disconnects. Connecting again asks for a new code.
    func forgetPairing() {
        if let serverID { pairedMacs.forget(serverID: serverID) }
        unlockStatus = nil
        disconnect()
    }

    private func handlePairChallenge(serverPublicKey: Data, salt: Data) {
        guard let privateKey = pairingPrivateKey else { return }
        do {
            let secret = try PairingCrypto.sharedSecret(privateKey: privateKey, peerPublicKey: serverPublicKey)
            pendingPairing = (PairingCrypto.sessionKey(from: secret, salt: salt),
                              PairingCrypto.presharedKey(from: secret, salt: salt))
            pairingState = .awaitingCode
        } catch {
            pairingState = .failed(String(localized: "pairing_failed"))
        }
    }

    private func handlePairResult(success: Bool, serverProof: Data?, message: String) {
        defer {
            pairingPrivateKey = nil
            pairingCode = nil
            pendingPairing = nil
        }
        guard success, let pending = pendingPairing, let code = pairingCode, let serverProof,
              PairingCrypto.constantTimeEquals(serverProof, PairingCrypto.serverProof(sessionKey: pending.sessionKey, code: code)),
              let serverID else {
            pairingState = .failed(success || message.isEmpty ? String(localized: "pairing_failed") : message)
            return
        }
        pairedMacs.upsert(PairedMac(serverID: serverID,
                                    name: connectedServerName ?? serverID,
                                    presharedKey: pending.presharedKey.rawData,
                                    pairedAt: Date()))
        isPaired = true
        pairingState = .succeeded
        if let tlsPort { upgradeToTLS(serverID: serverID, port: tlsPort) }
    }

    // MARK: - Sending Messages

    func send(_ message: RemoteMessage) {
        guard let connection = connection, isConnected else { return }
        send(message, on: connection)
    }

    private func send(_ message: RemoteMessage, on connection: NWConnection) {
        do {
            let data = try MessageFrame.encode(message)
            connection.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    print("[Client] Send error: \(error)")
                }
            })
        } catch {
            print("[Client] Encode error: \(error)")
        }
    }

    func move(dx: Double, dy: Double) {
        send(.move(dx: dx, dy: dy))
    }

    func click(button: RemoteMessage.MouseButton = .left) {
        send(.click(button: button))
    }

    func doubleClick(button: RemoteMessage.MouseButton = .left) {
        send(.doubleClick(button: button))
    }

    func scroll(dx: Double, dy: Double) {
        send(.scroll(dx: dx, dy: dy))
    }

    func keyPress(code: UInt16, flags: UInt64 = 0) {
        send(.key(code: code, down: true, flags: flags))
        send(.key(code: code, down: false, flags: flags))
    }

    /// Types text on the Mac as Unicode, independent of keyboard layout.
    func typeText(_ text: String) {
        guard !text.isEmpty else { return }
        send(.text(text))
    }

    // MARK: - Media Controls

    func playPause() {
        send(.media(action: .playPause))
    }

    func nextTrack() {
        send(.media(action: .nextTrack))
    }

    func previousTrack() {
        send(.media(action: .previousTrack))
    }

    func volumeUp() {
        send(.media(action: .volumeUp))
    }

    func volumeDown() {
        send(.media(action: .volumeDown))
    }

    func mute() {
        send(.media(action: .mute))
    }

    // MARK: - Brightness Controls

    func brightnessUp() {
        send(.media(action: .brightnessUp))
    }

    func brightnessDown() {
        send(.media(action: .brightnessDown))
    }

    // MARK: - System Controls

    func lockScreen() {
        send(.system(action: .lock))
    }

    func requestUnlock() {
        guard isUnlockAvailable, let challenge = unlockChallenge else {
            unlockStatus = String(localized: "unlock_not_available")
            return
        }
        guard let serverID, let presharedKey = pairedMacs.presharedKey(for: serverID) else {
            unlockStatus = String(localized: "unlock_pair_first")
            return
        }

        let context = LAContext()
        context.localizedCancelTitle = String(localized: "cancel")
        isAuthenticatingForUnlock = true
        context.evaluatePolicy(
            .deviceOwnerAuthentication,
            localizedReason: String(localized: "unlock_auth_reason")
        ) { [weak self] success, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isAuthenticatingForUnlock = false
                guard success else {
                    self.unlockStatus = error?.localizedDescription ?? String(localized: "unlock_auth_failed")
                    return
                }
                let signature = PairingCrypto.unlockSignature(presharedKey: presharedKey, challenge: challenge)
                self.unlockStatus = String(localized: "unlock_sending")
                self.send(.unlock(signature: signature))
            }
        }
    }

    // MARK: - App Launcher

    func requestAppList() {
        DispatchQueue.main.async {
            self.isLoadingApps = true
        }
        send(.requestAppList)
    }

    func launchApp(bundleId: String) {
        send(.launchApp(bundleId: bundleId))
    }

    // MARK: - Screen Streaming

    func startScreenStream(quality: RemoteMessage.StreamQuality = .medium) {
        send(.startScreenStream(quality: quality))
    }

    func stopScreenStream() {
        send(.stopScreenStream)
    }

    // MARK: - Receiving

    private func startReceiving(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if isComplete || error != nil {
                DispatchQueue.main.async {
                    // Only the live connection's end matters; an upgraded-away plaintext link is expected to close.
                    if connection === self.connection {
                        self.isConnected = false
                    }
                }
                return
            }

            guard let lengthData = data, lengthData.count == 4 else {
                self.startReceiving(on: connection)
                return
            }

            let length = lengthData.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }

            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] messageData, _, _, error in
                guard let self = self else { return }

                if let error = error {
                    print("[Client] Receive error: \(error)")
                }

                if let data = messageData {
                    do {
                        let message = try MessageFrame.decode(data, as: ServerMessage.self)
                        DispatchQueue.main.async {
                            guard connection === self.connection || connection === self.pendingSecure else { return }
                            self.handleMessage(message)
                        }
                    } catch {
                        print("[Client] Decode error: \(error)")
                    }
                } else {
                    print("[Client] No data received")
                }

                self.startReceiving(on: connection)
            }
        }
    }

    private func handleMessage(_ message: ServerMessage) {
        switch message {
        case .connected(let width, let height, let challenge, let unlockAvailable):
            screenSize = CGSize(width: width, height: height)
            unlockChallenge = challenge
            isUnlockAvailable = unlockAvailable
            print("[Client] Screen size: \(screenSize)")

        case .pong:
            print("[Client] Pong received")

        case .error(let message):
            connectionError = message

        case .appList(let appList):
            print("[Client] Processing app list with \(appList.count) apps")
            apps = appList
            isLoadingApps = false
            print("[Client] App list loaded successfully")

        case .screenFrame(let frame):
            onScreenFrameReceived?(frame)

        case .screenStreamStarted:
            isScreenStreaming = true
            print("[Client] Screen streaming started")

        case .screenStreamStopped:
            isScreenStreaming = false
            print("[Client] Screen streaming stopped")

        case .unlockResult(let success, let message):
            unlockStatus = success ? String(localized: "unlock_command_sent") : message

        case .unlockChallenge(let challenge):
            unlockChallenge = challenge

        case .screenLockState(let locked):
            isScreenLocked = locked

        case .wakeInfo(let interfaces, let wakeEnabled):
            if let name = connectedServerName {
                knownMacs.update(name: name, interfaces: interfaces, wakeForNetworkAccessEnabled: wakeEnabled)
            }

        case .welcome(let id, let name, _, let port, _, let allowed):
            serverID = id
            if connectedServerName == nil { connectedServerName = name }
            if connectingName == nil { connectingName = name }
            tlsPort = port
            controlAllowed = allowed || isSecure
            isPaired = isSecure || pairedMacs.presharedKey(for: id) != nil
            if !isSecure, pendingSecure == nil, pairingState == .idle {
                if isPaired, let port {
                    upgradeToTLS(serverID: id, port: port)
                } else {
                    beginPairing()
                }
            }

        case .pairChallenge(let publicKey, let salt):
            handlePairChallenge(serverPublicKey: publicKey, salt: salt)

        case .pairResult(let success, let serverProof, let message):
            handlePairResult(success: success, serverProof: serverProof, message: message)
        }
    }
}
