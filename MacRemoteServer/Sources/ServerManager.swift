import Foundation
import AppKit
import Combine
import CryptoKit
import Network
import SwiftUI

/// Coordinates the network servers, permissions, pairing, input injection and
/// screen streaming, and exposes a single observable state for the UI.
///
/// Two listeners run side by side:
/// - the **plaintext** listener on the configured port, advertised over Bonjour.
///   It handles discovery and pairing, and (while `allowUnencryptedConnections`
///   is on) legacy control from unpaired clients;
/// - the **encrypted** listener on the next port, TLS 1.2 with one pre-shared key
///   per paired device. Only paired devices can complete its handshake.
@MainActor
final class ServerManager: ObservableObject {

    // MARK: - Public state

    enum Status: Equatable {
        case stopped
        case starting
        case running
        case needsAttention(Problem)
    }

    enum Problem: Equatable {
        case accessibilityMissing
        case portInUse(UInt16)
        case listenerFailed(String)
    }

    struct ConnectedDevice: Identifiable, Equatable {
        let id: ObjectIdentifier
        var name: String?
        let address: String
        let connectedAt: Date
        let isSecure: Bool
        var isPaired = false
        var isStreaming = false

        var displayName: String { name ?? address }
    }

    enum Activity: Equatable {
        case streaming(to: String, quality: RemoteMessage.StreamQuality)
        case unlockSent(Date)
        case unlockRejected(Date)
        case appLaunched(String, Date)
        case paired(String, Date)
    }

    enum OnboardingStep: Int, CaseIterable, Identifiable {
        case welcome
        case accessibility
        case screenRecording
        case start
        case done

        var id: Int { rawValue }
    }

    /// An active "Pair a Device" window.
    struct PairingSession: Equatable {
        enum Phase: Equatable {
            case waiting
            case inProgress(deviceName: String)
            case succeeded(deviceName: String)
            case failed(reason: String)
        }
        let code: String
        let startedAt: Date
        let expiresAt: Date
        var phase: Phase = .waiting

        var isOpen: Bool {
            if case .waiting = phase { return Date() < expiresAt }
            if case .inProgress = phase { return Date() < expiresAt }
            return false
        }
    }

    static let pairingWindow: TimeInterval = 60

    let settings: AppSettings
    let permissions: PermissionsMonitor

    @Published private(set) var status: Status = .stopped
    @Published private(set) var devices: [ConnectedDevice] = []
    @Published private(set) var pairedDevices: [PairedDevice] = []
    @Published private(set) var pairingSession: PairingSession?
    @Published private(set) var isScreenStreaming = false
    @Published private(set) var lastActivity: Activity?
    @Published private(set) var advertisedName: String?
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var securePort: UInt16?
    @Published private(set) var isRemoteUnlockConfigured = false

    /// Set when the UI should open onboarding at a specific step (e.g. "Fix" in the popover).
    @Published var requestedOnboardingStep: OnboardingStep?
    /// Set when the UI should open the pairing window.
    @Published var pairingRequested = false

    // MARK: - Private

    private let plainServer = NetworkServer()
    private let secureServer = NetworkServer()
    private let inputController = InputController()
    private let screenCaptureManager = ScreenCaptureManager()
    private let remoteUnlockStore = RemoteUnlockStore()
    private let pairedStore: PairedDeviceStore
    private let appCatalog = AppCatalog()

    /// Per-connection state. Keyed by the connection's identity.
    private struct Context {
        let connection: NWConnection
        let isSecure: Bool
        var deviceID: String?
        var protocolVersion = 1
        var warnedUnauthorized = false
        var pairing: PairingExchange?
    }

    /// In-flight key agreement for one pairing attempt.
    private struct PairingExchange {
        let deviceID: String
        let deviceName: String
        let privateKey: Curve25519.KeyAgreement.PrivateKey
        let salt: Data
        let sessionKey: SymmetricKey
        let presharedKey: SymmetricKey
    }

    private var contexts: [ObjectIdentifier: Context] = [:]
    private var unlockChallenges: [ObjectIdentifier: Data] = [:]
    private var lockStateTimer: Timer?
    private var lastReportedLockState: Bool?
    private var plainState: NetworkServer.State = .stopped
    private var secureState: NetworkServer.State = .stopped
    private var userStoppedExplicitly = false
    private var pendingRestart = false
    private var pairingExpiryTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(settings: AppSettings, permissions: PermissionsMonitor, pairedStore: PairedDeviceStore = PairedDeviceStore()) {
        self.settings = settings
        self.permissions = permissions
        self.pairedStore = pairedStore
        pairedDevices = pairedStore.devices
        refreshRemoteUnlockConfiguration()
        setupServerCallbacks(for: plainServer, secure: false)
        setupServerCallbacks(for: secureServer, secure: true)
        setupScreenCaptureCallbacks()
        observePermissions()
        observeSettings()
        recomputeStatus()

        if settings.autoStartServer, permissions.allRequiredGranted {
            start()
        }
    }

    // MARK: - Derived

    var isRunning: Bool { status == .running }

    var problem: Problem? {
        if case .needsAttention(let problem) = status { return problem }
        return nil
    }

    var connectedCount: Int { devices.count }

    // MARK: - Server control

    func start() {
        userStoppedExplicitly = false
        guard permissions.allRequiredGranted else {
            recomputeStatus()
            return
        }
        let txt = [
            NetworkConstants.TXTKey.tlsPort: String(settings.tlsPort),
            NetworkConstants.TXTKey.protocolVersion: String(NetworkConstants.protocolVersion)
        ]
        plainServer.start(port: settings.effectivePort, serviceName: settings.effectiveServiceName, txtRecord: txt)
        startSecureServerIfPossible()
    }

    func stop() {
        userStoppedExplicitly = true
        cancelPairing()
        stopLockStateMonitor()
        Task { await stopScreenStreaming() }
        inputController.releaseAllButtons()
        plainServer.stop()
        secureServer.stop()
    }

    func toggle() {
        switch status {
        case .running, .starting:
            stop()
        case .stopped, .needsAttention:
            start()
        }
    }

    /// Applies new name/port settings to a running server.
    func restartIfRunning() {
        guard case .running = plainState else { return }
        pendingRestart = true
        plainServer.stop()
        secureServer.stop()
    }

    /// The encrypted listener needs at least one key, so it only runs once a device is paired.
    private func startSecureServerIfPossible() {
        let keys = pairedDevices.map { NetworkServer.TLSConfiguration.PresharedKey(identity: $0.id, key: $0.presharedKey) }
        guard !keys.isEmpty else { return }
        secureServer.start(port: settings.tlsPort, serviceName: nil, tls: .init(presharedKeys: keys))
    }

    /// Called whenever the set of paired devices changes: the TLS options are fixed
    /// per listener, so it is restarted with the new key set.
    private func reloadSecureServer() {
        pairedDevices = pairedStore.devices
        guard case .running = plainState else { return }
        secureServer.stop()
        startSecureServerIfPossible()
    }

    // MARK: - Pairing

    func startPairing() {
        pairingExpiryTask?.cancel()
        let now = Date()
        pairingSession = PairingSession(code: PairingCrypto.randomCode(), startedAt: now,
                                        expiresAt: now.addingTimeInterval(Self.pairingWindow))
        pairingExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingWindow))
            guard !Task.isCancelled, let self else { return }
            if let session = self.pairingSession, session.isOpen == false, case .waiting = session.phase {
                self.pairingSession?.phase = .failed(reason: String(localized: "The code expired."))
            } else if let session = self.pairingSession, case .inProgress = session.phase {
                self.pairingSession?.phase = .failed(reason: String(localized: "The code expired."))
            }
        }
        print("[Pairing] Window opened")
    }

    func cancelPairing() {
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingSession = nil
        for id in contexts.keys { contexts[id]?.pairing = nil }
    }

    func forgetDevice(id: String) {
        pairedStore.remove(id: id)
        for (key, context) in contexts where context.deviceID == id {
            context.connection.cancel()
            contexts.removeValue(forKey: key)
        }
        reloadSecureServer()
    }

    func renameDevice(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pairedStore.rename(id: id, to: trimmed)
        pairedDevices = pairedStore.devices
        for index in devices.indices where contexts[devices[index].id]?.deviceID == id {
            devices[index].name = trimmed
        }
    }

    private func handlePairRequest(deviceID: String, deviceName: String, publicKey: Data, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard var context = contexts[id] else { return }

        guard !context.isSecure else {
            plainServer.send(.pairResult(success: false, serverProof: nil, message: "Already paired."), to: connection)
            return
        }
        guard var session = pairingSession, session.isOpen, case .waiting = session.phase else {
            send(.pairResult(success: false, serverProof: nil,
                             message: "No pairing in progress. Choose Pair a Device on the Mac first."), to: connection)
            return
        }

        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let salt = PairingCrypto.randomBytes(PairingCrypto.saltLength)
        let secret: SharedSecret
        do {
            secret = try PairingCrypto.sharedSecret(privateKey: privateKey, peerPublicKey: publicKey)
        } catch {
            send(.pairResult(success: false, serverProof: nil, message: "Invalid pairing request."), to: connection)
            return
        }

        context.pairing = PairingExchange(
            deviceID: deviceID,
            deviceName: deviceName,
            privateKey: privateKey,
            salt: salt,
            sessionKey: PairingCrypto.sessionKey(from: secret, salt: salt),
            presharedKey: PairingCrypto.presharedKey(from: secret, salt: salt)
        )
        contexts[id] = context
        session.phase = .inProgress(deviceName: deviceName)
        pairingSession = session

        send(.pairChallenge(publicKey: privateKey.publicKey.rawRepresentation, salt: salt), to: connection)
        print("[Pairing] Challenge sent to \(deviceName)")
    }

    private func handlePairConfirm(proof: Data, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard var context = contexts[id], let exchange = context.pairing else {
            send(.pairResult(success: false, serverProof: nil, message: "No pairing in progress."), to: connection)
            return
        }
        context.pairing = nil
        contexts[id] = context

        guard var session = pairingSession, session.isOpen else {
            send(.pairResult(success: false, serverProof: nil, message: "The code expired."), to: connection)
            return
        }

        let expected = PairingCrypto.clientProof(sessionKey: exchange.sessionKey, code: session.code)
        guard PairingCrypto.constantTimeEquals(proof, expected) else {
            // One attempt per code: close the window so the code cannot be brute-forced.
            session.phase = .failed(reason: String(localized: "The code entered on the device was wrong."))
            pairingSession = session
            pairingExpiryTask?.cancel()
            send(.pairResult(success: false, serverProof: nil, message: "Wrong code."), to: connection)
            print("[Pairing] Wrong code from \(exchange.deviceName)")
            return
        }

        let device = PairedDevice(id: exchange.deviceID, name: exchange.deviceName,
                                  presharedKey: exchange.presharedKey.rawData, pairedAt: Date(), lastSeen: Date())
        pairedStore.upsert(device)

        context.deviceID = device.id
        contexts[id] = context
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].name = device.name
            devices[index].isPaired = true
        }

        session.phase = .succeeded(deviceName: device.name)
        pairingSession = session
        pairingExpiryTask?.cancel()
        lastActivity = .paired(device.name, Date())

        send(.pairResult(success: true,
                         serverProof: PairingCrypto.serverProof(sessionKey: exchange.sessionKey, code: session.code),
                         message: "Paired."), to: connection)
        sendWelcome(to: connection)
        print("[Pairing] Paired with \(device.name)")

        reloadSecureServer()
    }

    // MARK: - Remote Unlock configuration

    @discardableResult
    func configureRemoteUnlock(password: String) -> Bool {
        let configured = remoteUnlockStore.configure(password: password)
        refreshRemoteUnlockConfiguration()
        return configured
    }

    func disableRemoteUnlock() {
        remoteUnlockStore.removeConfiguration()
        refreshRemoteUnlockConfiguration()
    }

    /// Reads the legacy pairing key from the Keychain. Only call on explicit user intent
    /// (Reveal / Copy), because it may show a Keychain prompt.
    func revealPairingKey() -> String? {
        remoteUnlockStore.formattedPairingKey
    }

    private func refreshRemoteUnlockConfiguration() {
        isRemoteUnlockConfigured = remoteUnlockStore.isConfigured
    }

    // MARK: - Status

    private func recomputeStatus() {
        let newStatus: Status
        if !permissions.allRequiredGranted {
            newStatus = .needsAttention(.accessibilityMissing)
        } else if case .failed(let failure) = secureState {
            newStatus = .needsAttention(Self.problem(for: failure))
        } else {
            switch plainState {
            case .stopped: newStatus = .stopped
            case .starting: newStatus = .starting
            case .running: newStatus = .running
            case .failed(let failure): newStatus = .needsAttention(Self.problem(for: failure))
            }
        }
        if newStatus != status {
            status = newStatus
        }
    }

    private static func problem(for failure: NetworkServer.Failure) -> Problem {
        switch failure {
        case .portInUse(let port): return .portInUse(port)
        case .other(let message): return .listenerFailed(message)
        }
    }

    private func observePermissions() {
        permissions.$accessibility
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] granted in
                guard let self else { return }
                self.recomputeStatus()
                if granted, self.settings.autoStartServer, !self.userStoppedExplicitly,
                   case .stopped = self.plainState {
                    self.start()
                } else if !granted {
                    self.plainServer.stop()
                    self.secureServer.stop()
                }
            }
            .store(in: &cancellables)

        permissions.$screenRecording
            .removeDuplicates()
            .sink { [weak self] _ in self?.screenCaptureManager.checkPermission() }
            .store(in: &cancellables)
    }

    private func observeSettings() {
        settings.$showCursorInStream
            .sink { [weak self] value in self?.screenCaptureManager.showsCursor = value }
            .store(in: &cancellables)
        settings.$sharedDisplayID
            .sink { [weak self] value in self?.screenCaptureManager.preferredDisplayID = value }
            .store(in: &cancellables)
        settings.$allowUnencryptedConnections
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                // Tell every plaintext client whether it may still send control messages.
                for context in self.contexts.values where !context.isSecure {
                    self.sendWelcome(to: context.connection)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Server callbacks

    private func setupServerCallbacks(for server: NetworkServer, secure: Bool) {
        server.onStateChanged = { [weak self] state in
            guard let self else { return }
            if secure {
                self.secureState = state
                if case .running(let port) = state { self.securePort = port } else { self.securePort = nil }
            } else {
                self.plainState = state
                if case .running(let port) = state { self.listeningPort = port } else { self.listeningPort = nil }
                if case .stopped = state {
                    self.advertisedName = nil
                    if self.pendingRestart {
                        self.pendingRestart = false
                        self.start()
                    }
                }
            }
            if case .stopped = state {
                let dropped = self.contexts.filter { $0.value.isSecure == secure }.map(\.key)
                for id in dropped { self.forget(connectionID: id) }
            }
            self.recomputeStatus()
        }

        server.onAdvertisedNameChanged = { [weak self] name in
            self?.advertisedName = name
        }

        server.onClientConnected = { [weak self] connection in
            guard let self else { return }
            let id = ObjectIdentifier(connection)
            self.contexts[id] = Context(connection: connection, isSecure: secure)
            self.devices.append(ConnectedDevice(id: id, address: connection.peerDescription,
                                                connectedAt: Date(), isSecure: secure))

            let challenge = RemoteUnlockStore.randomBytes(count: 32)
            self.unlockChallenges[id] = challenge
            let screenSize = self.inputController.screenSize
            self.send(
                .connected(
                    screenWidth: screenSize.width,
                    screenHeight: screenSize.height,
                    unlockChallenge: self.isRemoteUnlockConfigured ? challenge : nil,
                    unlockAvailable: self.isRemoteUnlockConfigured
                ),
                to: connection
            )
            self.sendWelcome(to: connection)
            self.send(.screenLockState(isLocked: InputController.isScreenLocked), to: connection)
            self.startLockStateMonitor()
        }

        server.onClientDisconnected = { [weak self] connection in
            self?.forget(connectionID: ObjectIdentifier(connection))
        }

        server.onMessageReceived = { [weak self] message, connection in
            self?.handleMessage(message, from: connection)
        }
    }

    private func forget(connectionID id: ObjectIdentifier) {
        contexts.removeValue(forKey: id)
        unlockChallenges.removeValue(forKey: id)
        if contexts.isEmpty {
            stopLockStateMonitor()
        }
        let wasStreaming = devices.first(where: { $0.id == id })?.isStreaming ?? false
        devices.removeAll { $0.id == id }
        inputController.releaseAllButtons()
        if wasStreaming, !devices.contains(where: \.isStreaming) {
            Task { await stopScreenStreaming() }
        }
    }

    // MARK: - Lock state

    /// Polls the session lock state while clients are connected and reports changes, so a
    /// client can show whether the Mac is locked without asking.
    private func startLockStateMonitor() {
        guard lockStateTimer == nil else { return }
        lastReportedLockState = InputController.isScreenLocked
        lockStateTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollLockState() }
        }
    }

    private func stopLockStateMonitor() {
        lockStateTimer?.invalidate()
        lockStateTimer = nil
        lastReportedLockState = nil
    }

    private func pollLockState() {
        let locked = InputController.isScreenLocked
        guard locked != lastReportedLockState else { return }
        lastReportedLockState = locked
        for context in contexts.values {
            send(.screenLockState(isLocked: locked), to: context.connection)
        }
    }

    private func send(_ message: ServerMessage, to connection: NWConnection) {
        let secure = contexts[ObjectIdentifier(connection)]?.isSecure ?? false
        (secure ? secureServer : plainServer).send(message, to: connection)
    }

    private func sendWelcome(to connection: NWConnection) {
        guard let context = contexts[ObjectIdentifier(connection)] else { return }
        send(.welcome(
            serverName: settings.effectiveServiceName,
            protocolVersion: NetworkConstants.protocolVersion,
            tlsPort: securePort,
            isPaired: isPaired(context),
            controlAllowed: controlAllowed(context)
        ), to: connection)
    }

    private func isPaired(_ context: Context) -> Bool {
        guard let deviceID = context.deviceID else { return context.isSecure }
        return context.isSecure || pairedStore.device(id: deviceID) != nil
    }

    /// Control is allowed over TLS always, and over plaintext only in legacy mode.
    private func controlAllowed(_ context: Context) -> Bool {
        context.isSecure || settings.allowUnencryptedConnections
    }

    // MARK: - Message handling

    private func handleMessage(_ message: RemoteMessage, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard let context = contexts[id] else { return }

        // Messages every connection may send.
        switch message {
        case .hello(let deviceID, let deviceName, let version):
            handleHello(deviceID: deviceID, deviceName: deviceName, version: version, from: connection)
            return
        case .pairRequest(let deviceID, let deviceName, let publicKey):
            handlePairRequest(deviceID: deviceID, deviceName: deviceName, publicKey: publicKey, from: connection)
            return
        case .pairConfirm(let proof):
            handlePairConfirm(proof: proof, from: connection)
            return
        case .ping:
            send(.pong, to: connection)
            return
        default:
            break
        }

        guard controlAllowed(context) else {
            if !context.warnedUnauthorized {
                contexts[id]?.warnedUnauthorized = true
                send(.error(message: "This Mac only accepts paired devices. Open MacRemote on the Mac and choose Pair a Device."), to: connection)
            }
            return
        }

        switch message {
        case .move(let dx, let dy):
            inputController.moveMouse(dx: dx, dy: dy)
        case .click(let button):
            inputController.click(button: button)
        case .doubleClick(let button):
            inputController.doubleClick(button: button)
        case .mouseDown(let button):
            inputController.mouseDown(button: button)
        case .mouseUp(let button):
            inputController.mouseUp(button: button)
        case .scroll(let dx, let dy):
            inputController.scroll(dx: dx, dy: dy)
        case .key(let code, let down, let flags):
            inputController.keyEvent(code: code, down: down, flags: flags)
        case .text(let text):
            inputController.typeText(text)
        case .media(let action):
            inputController.mediaAction(action)
        case .system(let action):
            inputController.systemAction(action)
        case .requestAppList:
            let catalog = appCatalog
            let server = context.isSecure ? secureServer : plainServer
            Task.detached(priority: .userInitiated) {
                let apps = catalog.installedApps()
                server.send(.appList(apps: apps), to: connection)
            }
        case .launchApp(let bundleId):
            if inputController.launchApp(bundleId: bundleId) {
                lastActivity = .appLaunched(bundleId, Date())
            } else {
                send(.error(message: "Failed to launch app: \(bundleId)"), to: connection)
            }
        case .startScreenStream(let quality):
            startScreenStreaming(quality: quality, for: connection)
        case .stopScreenStream:
            stopScreenStreamingForClient(connection)
        case .unlock(let signature):
            handleUnlock(signature: signature, from: connection)
        case .hello, .pairRequest, .pairConfirm, .ping:
            break
        }
    }

    private func handleHello(deviceID: String, deviceName: String, version: Int, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard var context = contexts[id] else { return }
        context.deviceID = deviceID
        context.protocolVersion = version
        contexts[id] = context

        let paired = pairedStore.device(id: deviceID)
        if paired != nil {
            pairedStore.touch(id: deviceID)
            pairedDevices = pairedStore.devices
        }
        if let index = devices.firstIndex(where: { $0.id == id }) {
            devices[index].name = paired?.name ?? deviceName
            devices[index].isPaired = paired != nil || context.isSecure
        }
        sendWelcome(to: connection)
    }

    // MARK: - Screen streaming

    private func setStreaming(_ streaming: Bool, for id: ObjectIdentifier) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].isStreaming = streaming
    }

    private func startScreenStreaming(quality: RemoteMessage.StreamQuality, for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard permissions.screenRecording else {
            send(.error(message: String(localized: "Screen Recording permission is not granted on the Mac.")), to: connection)
            return
        }
        setStreaming(true, for: id)

        if isScreenStreaming {
            send(.screenStreamStarted, to: connection)
            return
        }

        Task {
            do {
                try await screenCaptureManager.startStreaming(quality: quality)
                isScreenStreaming = true
                let name = devices.first(where: { $0.id == id })?.displayName ?? connection.peerDescription
                lastActivity = .streaming(to: name, quality: quality)
                send(.screenStreamStarted, to: connection)
            } catch {
                print("[ServerManager] Failed to start screen streaming: \(error)")
                send(.error(message: "Failed to start screen streaming: \(error.localizedDescription)"), to: connection)
                setStreaming(false, for: id)
            }
        }
    }

    private func stopScreenStreamingForClient(_ connection: NWConnection) {
        setStreaming(false, for: ObjectIdentifier(connection))
        if !devices.contains(where: \.isStreaming) {
            Task { await stopScreenStreaming() }
        }
        send(.screenStreamStopped, to: connection)
    }

    private func stopScreenStreaming() async {
        guard isScreenStreaming else { return }
        await screenCaptureManager.stopStreaming()
        isScreenStreaming = false
        for index in devices.indices { devices[index].isStreaming = false }
        if case .streaming = lastActivity { lastActivity = nil }
    }

    private func setupScreenCaptureCallbacks() {
        screenCaptureManager.onFrameEncoded = { [weak self] frame in
            guard let self else { return }
            let streaming = self.devices.filter(\.isStreaming)
            guard !streaming.isEmpty else { return }
            let plainIDs = Set(streaming.filter { !$0.isSecure }.map(\.id))
            let secureIDs = Set(streaming.filter(\.isSecure).map(\.id))
            if !plainIDs.isEmpty {
                self.plainServer.sendToConnections(.screenFrame(frame: frame)) { plainIDs.contains(ObjectIdentifier($0)) }
            }
            if !secureIDs.isEmpty {
                self.secureServer.sendToConnections(.screenFrame(frame: frame)) { secureIDs.contains(ObjectIdentifier($0)) }
            }
        }
    }

    // MARK: - Unlock

    private func handleUnlock(signature: Data, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard let password = remoteUnlockStore.password, let challenge = unlockChallenges[id] else {
            send(.unlockResult(success: false, message: "Remote unlock is not configured on this Mac."), to: connection)
            return
        }

        // Paired devices sign with their pre-shared key; legacy clients with the old token.
        let expected: Data?
        if let deviceID = contexts[id]?.deviceID, let paired = pairedStore.device(id: deviceID) {
            expected = PairingCrypto.unlockSignature(presharedKey: paired.presharedKey, challenge: challenge)
        } else if let token = remoteUnlockStore.token {
            expected = Data(HMAC<SHA256>.authenticationCode(for: challenge + Data("unlock".utf8), using: SymmetricKey(data: token)))
        } else {
            expected = nil
        }

        let nextChallenge = RemoteUnlockStore.randomBytes(count: 32)
        unlockChallenges[id] = nextChallenge

        guard let expected, PairingCrypto.constantTimeEquals(signature, expected) else {
            lastActivity = .unlockRejected(Date())
            send(.unlockResult(success: false, message: "The pairing key is invalid."), to: connection)
            send(.unlockChallenge(nextChallenge), to: connection)
            return
        }

        let outcome = inputController.unlockScreen(password: password)
        let message: String
        switch outcome {
        case .posted:
            lastActivity = .unlockSent(Date())
            message = "Unlock command sent to the Mac."
        case .screenNotLocked:
            message = "The Mac is not locked."
        case .failed:
            message = "The Mac could not post unlock events."
        }
        send(.unlockResult(success: outcome == .posted, message: message), to: connection)
        send(.unlockChallenge(nextChallenge), to: connection)
    }
}
