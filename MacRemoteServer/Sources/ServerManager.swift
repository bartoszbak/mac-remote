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
///   It handles discovery and pairing only; no control messages are accepted on it.
///   A device connecting here for the first time triggers the pairing window;
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
        case screenRecordingMissing
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

    /// A device asking to connect. Started by the device's `pairRequest`; the Mac shows
    /// the code and the device must send proof of it.
    struct PairingSession: Equatable {
        enum Phase: Equatable {
            case waitingForCode
            case succeeded
            case failed(reason: String)
        }
        let code: String
        let deviceName: String
        let startedAt: Date
        let expiresAt: Date
        var phase: Phase = .waitingForCode

        var isOpen: Bool {
            phase == .waitingForCode && Date() < expiresAt
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
    /// Connection that the open pairing session belongs to.
    private var pairingConnectionID: ObjectIdentifier?

    // MARK: - Private

    private let plainServer = NetworkServer()
    private let secureServer = NetworkServer()
    private let input = InputDispatcher(controller: InputController())
    /// Direct access for main-queue reads and one-off actions; input events go through `input`.
    private var inputController: InputController { input.controller }
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
        closePairing()
        stopLockStateMonitor()
        Task { await stopScreenStreaming() }
        input.perform { $0.releaseAllButtons() }
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

    /// Called whenever the set of paired devices changes. TLS options are fixed per
    /// listener, so the listener is replaced; already-connected devices stay connected.
    private func reloadSecureServer() {
        pairedDevices = pairedStore.devices
        guard case .running = plainState else { return }
        let keys = pairedDevices.map { NetworkServer.TLSConfiguration.PresharedKey(identity: $0.id, key: $0.presharedKey) }
        if keys.isEmpty {
            secureServer.stop()
        } else if case .running = secureState {
            secureServer.replaceListener(port: settings.tlsPort, serviceName: nil, tls: .init(presharedKeys: keys))
        } else {
            secureServer.start(port: settings.tlsPort, serviceName: nil, tls: .init(presharedKeys: keys))
        }
    }

    // MARK: - Pairing

    /// Opens a pairing session for the device on `connectionID` and asks the UI to show it.
    private func openPairing(deviceName: String, connectionID: ObjectIdentifier) {
        pairingExpiryTask?.cancel()
        let now = Date()
        pairingSession = PairingSession(code: PairingCrypto.randomCode(), deviceName: deviceName, startedAt: now,
                                        expiresAt: now.addingTimeInterval(Self.pairingWindow))
        pairingConnectionID = connectionID
        pairingRequested = true
        pairingExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingWindow))
            guard !Task.isCancelled, let self else { return }
            self.failPairing(reason: String(localized: "The code expired."), tellDevice: "The code expired. Try again.")
        }
        print("[Pairing] \(deviceName) asked to connect")
    }

    /// Ends an open session as failed and tells the waiting device why.
    private func failPairing(reason: String, tellDevice message: String) {
        guard var session = pairingSession, session.phase == .waitingForCode else { return }
        session.phase = .failed(reason: reason)
        pairingSession = session
        pairingExpiryTask?.cancel()
        if let id = pairingConnectionID, let context = contexts[id] {
            contexts[id]?.pairing = nil
            send(.pairResult(success: false, serverProof: nil, message: message), to: context.connection)
        }
        pairingConnectionID = nil
    }

    /// The user refused the request on the Mac.
    func denyPairing() {
        failPairing(reason: String(localized: "You declined the request."), tellDevice: "The Mac declined the request.")
    }

    /// Called when the pairing window closes. Closing an open request declines it.
    func closePairing() {
        if pairingSession?.isOpen == true { denyPairing() }
        pairingExpiryTask?.cancel()
        pairingExpiryTask = nil
        pairingSession = nil
        pairingConnectionID = nil
    }

    func forgetDevice(id: String) {
        pairedStore.remove(id: id)
        for (key, context) in contexts where context.deviceID == id {
            context.connection.cancel()
            contexts.removeValue(forKey: key)
        }
        reloadSecureServer()
    }

    /// Drops a connected device. It stays paired and can reconnect from the phone.
    func disconnect(device id: ObjectIdentifier) {
        guard let context = contexts[id] else { return }
        context.connection.cancel()
        forget(connectionID: id)
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
            send(.pairResult(success: false, serverProof: nil, message: "Already paired."), to: connection)
            return
        }
        guard permissions.allRequiredGranted else {
            send(.pairResult(success: false, serverProof: nil, message: "The Mac is missing permissions. Check MacRemote on the Mac."), to: connection)
            return
        }
        // One request at a time. A device retrying replaces its own request.
        if pairingSession?.isOpen == true, pairingConnectionID != id {
            send(.pairResult(success: false, serverProof: nil,
                             message: "Another device is connecting to this Mac. Try again in a moment."), to: connection)
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
        openPairing(deviceName: deviceName, connectionID: id)

        send(.pairChallenge(publicKey: privateKey.publicKey.rawRepresentation, salt: salt), to: connection)
    }

    private func handlePairConfirm(proof: Data, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard var context = contexts[id], let exchange = context.pairing else {
            send(.pairResult(success: false, serverProof: nil, message: "No pairing in progress."), to: connection)
            return
        }
        context.pairing = nil
        contexts[id] = context

        guard var session = pairingSession, session.isOpen, pairingConnectionID == id else {
            send(.pairResult(success: false, serverProof: nil, message: "The code expired. Try again."), to: connection)
            return
        }

        let expected = PairingCrypto.clientProof(sessionKey: exchange.sessionKey, code: session.code)
        guard PairingCrypto.constantTimeEquals(proof, expected) else {
            // One attempt per code so it cannot be brute-forced; a retry gets a new code.
            print("[Pairing] Wrong code from \(exchange.deviceName)")
            failPairing(reason: String(localized: "The code entered on the device was wrong."),
                        tellDevice: "Wrong code. Try again to get a new one.")
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

        session.phase = .succeeded
        pairingSession = session
        pairingExpiryTask?.cancel()
        pairingConnectionID = nil
        lastActivity = .paired(device.name, Date())

        // Accept the new key before telling the device, so its TLS connection finds it.
        reloadSecureServer()
        send(.pairResult(success: true,
                         serverProof: PairingCrypto.serverProof(sessionKey: exchange.sessionKey, code: session.code),
                         message: "Paired."), to: connection)
        print("[Pairing] Paired with \(device.name)")
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

    private func refreshRemoteUnlockConfiguration() {
        isRemoteUnlockConfigured = remoteUnlockStore.isConfigured
    }

    // MARK: - Status

    private func recomputeStatus() {
        let newStatus: Status
        if !permissions.accessibility {
            newStatus = .needsAttention(.accessibilityMissing)
        } else if !permissions.screenRecording {
            newStatus = .needsAttention(.screenRecordingMissing)
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
            .dropFirst()
            .sink { [weak self] granted in
                guard let self else { return }
                self.screenCaptureManager.checkPermission()
                self.recomputeStatus()
                if granted, self.permissions.allRequiredGranted, self.settings.autoStartServer,
                   !self.userStoppedExplicitly, case .stopped = self.plainState {
                    self.start()
                } else if !granted {
                    self.plainServer.stop()
                    self.secureServer.stop()
                }
            }
            .store(in: &cancellables)
    }

    private func observeSettings() {
        settings.$showCursorInStream
            .sink { [weak self] value in self?.screenCaptureManager.showsCursor = value }
            .store(in: &cancellables)
        settings.$sharedDisplayID
            .sink { [weak self] value in self?.screenCaptureManager.preferredDisplayID = value }
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

            // A plaintext connection is only a doorway: it can identify itself and pair.
            // It is not a connected device and receives nothing about this Mac.
            guard secure else {
                self.sendWelcome(to: connection)
                return
            }
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
            self.send(.wakeInfo(interfaces: NetworkInterfaces.active(),
                                wakeForNetworkAccessEnabled: self.permissions.wakeForNetworkAccess), to: connection)
            self.send(.screenLockState(isLocked: InputController.isScreenLocked), to: connection)
            self.startLockStateMonitor()
        }

        server.onClientDisconnected = { [weak self] connection in
            self?.forget(connectionID: ObjectIdentifier(connection))
        }

        server.onMessageReceived = { [weak self] message, connection in
            self?.handleMessage(message, from: connection)
        }
        server.onPointerMessage = { [input] message, connection in
            input.handlePointerMessage(message, from: connection)
        }
    }

    private func forget(connectionID id: ObjectIdentifier) {
        if let context = contexts[id] {
            input.setAuthorized(false, for: context.connection)
        }
        if pairingConnectionID == id {
            failPairing(reason: String(localized: "The device disconnected."), tellDevice: "")
        }
        contexts.removeValue(forKey: id)
        unlockChallenges.removeValue(forKey: id)
        if contexts.isEmpty {
            stopLockStateMonitor()
        }
        let wasStreaming = devices.first(where: { $0.id == id })?.isStreaming ?? false
        devices.removeAll { $0.id == id }
        input.perform { $0.releaseAllButtons() }
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
        for context in contexts.values where context.isSecure {
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
            serverID: settings.serverID,
            serverName: settings.effectiveServiceName,
            protocolVersion: NetworkConstants.protocolVersion,
            tlsPort: securePort ?? settings.tlsPort,
            isPaired: isPaired(context),
            controlAllowed: controlAllowed(context)
        ), to: connection)
    }

    private func isPaired(_ context: Context) -> Bool {
        guard let deviceID = context.deviceID else { return context.isSecure }
        return context.isSecure || pairedStore.device(id: deviceID) != nil
    }

    /// Control is only ever allowed over the encrypted link of a paired device.
    private func controlAllowed(_ context: Context) -> Bool {
        context.isSecure
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
            input.setAuthorized(false, for: connection)
            if !context.warnedUnauthorized {
                contexts[id]?.warnedUnauthorized = true
                send(.error(message: "Pair this iPhone with the Mac to control it."), to: connection)
            }
            return
        }
        // From here on, pointer messages from this connection may skip the main queue.
        input.setAuthorized(true, for: connection)

        switch message {
        case .move(let dx, let dy):
            input.perform { $0.moveMouse(dx: dx, dy: dy) }
        case .click(let button):
            input.perform { $0.click(button: button) }
        case .doubleClick(let button):
            input.perform { $0.doubleClick(button: button) }
        case .mouseDown(let button):
            input.perform { $0.mouseDown(button: button) }
        case .mouseUp(let button):
            input.perform { $0.mouseUp(button: button) }
        case .scroll(let dx, let dy):
            input.perform { $0.scroll(dx: dx, dy: dy) }
        case .key(let code, let down, let flags):
            input.perform { $0.keyEvent(code: code, down: down, flags: flags) }
        case .text(let text):
            input.perform { $0.typeText(text) }
        case .media(let action):
            input.perform { $0.mediaAction(action) }
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

        // Only paired devices may unlock: the signature is an HMAC with the device's pre-shared key.
        let nextChallenge = RemoteUnlockStore.randomBytes(count: 32)
        unlockChallenges[id] = nextChallenge

        guard let deviceID = contexts[id]?.deviceID, let paired = pairedStore.device(id: deviceID) else {
            print("[Unlock] Rejected: device is not paired")
            send(.unlockResult(success: false, message: "Pair this iPhone with the Mac first."), to: connection)
            send(.unlockChallenge(nextChallenge), to: connection)
            return
        }

        let expected = PairingCrypto.unlockSignature(presharedKey: paired.presharedKey, challenge: challenge)
        guard PairingCrypto.constantTimeEquals(signature, expected) else {
            lastActivity = .unlockRejected(Date())
            print("[Unlock] Rejected: bad signature from \(paired.name)")
            send(.unlockResult(success: false, message: "The unlock request could not be verified. Pair the iPhone again."), to: connection)
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
