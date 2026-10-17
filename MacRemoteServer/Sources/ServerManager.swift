import Foundation
import AppKit
import Combine
import CryptoKit
import Network
import SwiftUI

/// Coordinates the network server, permissions, input injection and screen
/// streaming, and exposes a single observable state for the UI.
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
        let address: String
        let connectedAt: Date
        var isStreaming = false
    }

    enum Activity: Equatable {
        case streaming(to: String, quality: RemoteMessage.StreamQuality)
        case unlockSent(Date)
        case unlockRejected(Date)
        case appLaunched(String, Date)
    }

    enum OnboardingStep: Int, CaseIterable, Identifiable {
        case welcome
        case accessibility
        case screenRecording
        case start
        case done

        var id: Int { rawValue }
    }

    let settings: AppSettings
    let permissions: PermissionsMonitor

    @Published private(set) var status: Status = .stopped
    @Published private(set) var devices: [ConnectedDevice] = []
    @Published private(set) var isScreenStreaming = false
    @Published private(set) var lastActivity: Activity?
    @Published private(set) var advertisedName: String?
    @Published private(set) var listeningPort: UInt16?
    @Published private(set) var isRemoteUnlockConfigured = false

    /// Set when the UI should open onboarding at a specific step (e.g. "Fix" in the popover).
    @Published var requestedOnboardingStep: OnboardingStep?

    // MARK: - Private

    private let server = NetworkServer()
    private let inputController = InputController()
    private let screenCaptureManager = ScreenCaptureManager()
    private let remoteUnlockStore = RemoteUnlockStore()
    private let appCatalog = AppCatalog()

    private var connectionsByID: [ObjectIdentifier: NWConnection] = [:]
    private var unlockChallenges: [ObjectIdentifier: Data] = [:]
    private var serverState: NetworkServer.State = .stopped
    private var userStoppedExplicitly = false
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(settings: AppSettings, permissions: PermissionsMonitor) {
        self.settings = settings
        self.permissions = permissions
        refreshRemoteUnlockConfiguration()
        setupServerCallbacks()
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
        server.start(port: settings.effectivePort, serviceName: settings.effectiveServiceName)
    }

    func stop() {
        userStoppedExplicitly = true
        Task { await stopScreenStreaming() }
        inputController.releaseAllButtons()
        server.stop()
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
        guard case .running = serverState else { return }
        server.stop()
        // The listener reports `.stopped` asynchronously; restart once it has.
        pendingRestart = true
    }

    private var pendingRestart = false

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

    /// Reads the pairing key from the Keychain. Only call on explicit user intent
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
        } else {
            switch serverState {
            case .stopped:
                newStatus = .stopped
            case .starting:
                newStatus = .starting
            case .running:
                newStatus = .running
            case .failed(let failure):
                switch failure {
                case .portInUse(let port):
                    newStatus = .needsAttention(.portInUse(port))
                case .other(let message):
                    newStatus = .needsAttention(.listenerFailed(message))
                }
            }
        }
        if newStatus != status {
            status = newStatus
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
                   case .stopped = self.serverState {
                    self.start()
                } else if !granted {
                    self.server.stop()
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
    }

    // MARK: - Server callbacks

    private func setupServerCallbacks() {
        server.onStateChanged = { [weak self] state in
            guard let self else { return }
            self.serverState = state
            if case .running(let port) = state {
                self.listeningPort = port
            } else {
                self.listeningPort = nil
            }
            if case .stopped = state {
                self.devices.removeAll()
                self.connectionsByID.removeAll()
                self.unlockChallenges.removeAll()
                self.advertisedName = nil
                if self.pendingRestart {
                    self.pendingRestart = false
                    self.start()
                }
            }
            self.recomputeStatus()
        }

        server.onAdvertisedNameChanged = { [weak self] name in
            self?.advertisedName = name
        }

        server.onClientConnected = { [weak self] connection in
            guard let self else { return }
            let id = ObjectIdentifier(connection)
            self.connectionsByID[id] = connection
            self.devices.append(ConnectedDevice(id: id, address: connection.peerDescription, connectedAt: Date()))

            let challenge = RemoteUnlockStore.randomBytes(count: 32)
            self.unlockChallenges[id] = challenge
            let screenSize = self.inputController.screenSize
            self.server.send(
                .connected(
                    screenWidth: screenSize.width,
                    screenHeight: screenSize.height,
                    unlockChallenge: self.isRemoteUnlockConfigured ? challenge : nil,
                    unlockAvailable: self.isRemoteUnlockConfigured
                ),
                to: connection
            )
        }

        server.onClientDisconnected = { [weak self] connection in
            guard let self else { return }
            let id = ObjectIdentifier(connection)
            self.connectionsByID.removeValue(forKey: id)
            self.unlockChallenges.removeValue(forKey: id)
            let wasStreaming = self.devices.first(where: { $0.id == id })?.isStreaming ?? false
            self.devices.removeAll { $0.id == id }
            self.inputController.releaseAllButtons()
            if wasStreaming, !self.devices.contains(where: \.isStreaming) {
                Task { await self.stopScreenStreaming() }
            }
        }

        server.onMessageReceived = { [weak self] message, connection in
            self?.handleMessage(message, from: connection)
        }
    }

    // MARK: - Message handling

    private func handleMessage(_ message: RemoteMessage, from connection: NWConnection) {
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
        case .ping:
            server.send(.pong, to: connection)
        case .requestAppList:
            let catalog = appCatalog
            Task.detached(priority: .userInitiated) { [server] in
                let apps = catalog.installedApps()
                server.send(.appList(apps: apps), to: connection)
            }
        case .launchApp(let bundleId):
            if inputController.launchApp(bundleId: bundleId) {
                lastActivity = .appLaunched(bundleId, Date())
            } else {
                server.send(.error(message: "Failed to launch app: \(bundleId)"), to: connection)
            }
        case .startScreenStream(let quality):
            startScreenStreaming(quality: quality, for: connection)
        case .stopScreenStream:
            stopScreenStreamingForClient(connection)
        case .unlock(let signature):
            handleUnlock(signature: signature, from: connection)
        }
    }

    // MARK: - Screen streaming

    private func setStreaming(_ streaming: Bool, for id: ObjectIdentifier) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].isStreaming = streaming
    }

    private func startScreenStreaming(quality: RemoteMessage.StreamQuality, for connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard permissions.screenRecording else {
            server.send(.error(message: String(localized: "Screen Recording permission is not granted on the Mac.")), to: connection)
            return
        }
        setStreaming(true, for: id)

        if isScreenStreaming {
            server.send(.screenStreamStarted, to: connection)
            return
        }

        Task {
            do {
                try await screenCaptureManager.startStreaming(quality: quality)
                isScreenStreaming = true
                lastActivity = .streaming(to: connection.peerDescription, quality: quality)
                server.send(.screenStreamStarted, to: connection)
            } catch {
                print("[ServerManager] Failed to start screen streaming: \(error)")
                server.send(.error(message: "Failed to start screen streaming: \(error.localizedDescription)"), to: connection)
                setStreaming(false, for: id)
            }
        }
    }

    private func stopScreenStreamingForClient(_ connection: NWConnection) {
        setStreaming(false, for: ObjectIdentifier(connection))
        if !devices.contains(where: \.isStreaming) {
            Task { await stopScreenStreaming() }
        }
        server.send(.screenStreamStopped, to: connection)
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
            let streamingIDs = Set(self.devices.filter(\.isStreaming).map(\.id))
            guard !streamingIDs.isEmpty else { return }
            self.server.sendToConnections(.screenFrame(frame: frame)) { connection in
                streamingIDs.contains(ObjectIdentifier(connection))
            }
        }
    }

    // MARK: - Unlock

    private func handleUnlock(signature: Data, from connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        guard let token = remoteUnlockStore.token,
              let password = remoteUnlockStore.password,
              let challenge = unlockChallenges[id] else {
            server.send(.unlockResult(success: false, message: "Remote unlock is not configured on this Mac."), to: connection)
            return
        }

        let expected = Data(HMAC<SHA256>.authenticationCode(
            for: challenge + Data("unlock".utf8),
            using: SymmetricKey(data: token)
        ))
        let nextChallenge = RemoteUnlockStore.randomBytes(count: 32)
        unlockChallenges[id] = nextChallenge

        guard signature.constantTimeEquals(expected) else {
            lastActivity = .unlockRejected(Date())
            server.send(.unlockResult(success: false, message: "The pairing key is invalid."), to: connection)
            server.send(.unlockChallenge(nextChallenge), to: connection)
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
        server.send(.unlockResult(success: outcome == .posted, message: message), to: connection)
        server.send(.unlockChallenge(nextChallenge), to: connection)
    }
}

private extension Data {
    func constantTimeEquals(_ other: Data) -> Bool {
        guard count == other.count else { return false }
        return zip(self, other).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
