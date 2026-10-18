import Foundation

/// Information about an installed application
struct AppInfo: Codable, Identifiable, Hashable, Sendable {
    let name: String
    let bundleId: String
    let icon: Data?

    var id: String { bundleId }

    func hash(into hasher: inout Hasher) {
        hasher.combine(bundleId)
    }

    static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
        lhs.bundleId == rhs.bundleId
    }
}

/// Messages sent from iOS client to macOS server
enum RemoteMessage: Codable {
    case move(dx: Double, dy: Double)
    case click(button: MouseButton)
    case doubleClick(button: MouseButton)
    case mouseDown(button: MouseButton)
    case mouseUp(button: MouseButton)
    case scroll(dx: Double, dy: Double)
    case key(code: UInt16, down: Bool, flags: UInt64)
    /// Arbitrary Unicode text, typed on the Mac regardless of its keyboard layout.
    case text(String)
    case media(action: MediaAction)
    case system(action: SystemAction)
    case ping
    case requestAppList
    case launchApp(bundleId: String)
    case startScreenStream(quality: StreamQuality)
    case stopScreenStream
    case unlock(signature: Data)

    // MARK: Identity and pairing (protocol v2)

    /// First message on a connection. `deviceID` is a stable per-install UUID.
    case hello(deviceID: String, deviceName: String, protocolVersion: Int)

    /// Starts pairing. `publicKey` is a Curve25519 key-agreement public key.
    /// Only accepted while the Mac shows a pairing code.
    case pairRequest(deviceID: String, deviceName: String, publicKey: Data)

    /// Proves knowledge of the pairing code: `PairingCrypto.clientProof`.
    case pairConfirm(proof: Data)

    enum StreamQuality: String, Codable {
        case low      // 480p, lower bitrate
        case medium   // 720p, balanced
        case high     // 1080p, higher bitrate
    }

    enum MouseButton: String, Codable {
        case left
        case right
    }

    enum MediaAction: String, Codable {
        case playPause
        case nextTrack
        case previousTrack
        case volumeUp
        case volumeDown
        case mute
        case brightnessUp
        case brightnessDown
    }

    enum SystemAction: String, Codable {
        case lock
    }
}

/// Messages sent from macOS server to iOS client
enum ServerMessage: Codable {
    case connected(screenWidth: Double, screenHeight: Double, unlockChallenge: Data?, unlockAvailable: Bool)
    case pong
    case error(message: String)
    case appList(apps: [AppInfo])
    case screenFrame(frame: ScreenFrame)
    case screenStreamStarted
    case screenStreamStopped
    case unlockResult(success: Bool, message: String)
    case unlockChallenge(Data)
    /// Whether the Mac's screen is currently locked. Sent on connect and on every change.
    case screenLockState(isLocked: Bool)

    // MARK: Identity and pairing (protocol v2)

    /// Sent right after `connected`. Tells the client how to reach the encrypted
    /// endpoint and whether this connection is allowed to send control messages.
    case welcome(serverID: String, serverName: String, protocolVersion: Int, tlsPort: UInt16?, isPaired: Bool, controlAllowed: Bool)

    /// Reply to `pairRequest`: the server's Curve25519 public key and HKDF salt.
    case pairChallenge(publicKey: Data, salt: Data)

    /// Final pairing outcome. On success `serverProof` lets the client verify the Mac
    /// knew the code too, and both sides derive the same long-term key.
    case pairResult(success: Bool, serverProof: Data?, message: String)

    /// Sent after `welcome`. Lets the client store what it needs to wake this Mac from
    /// sleep with a Wake-on-LAN magic packet (see `WakeOnLAN`).
    case wakeInfo(interfaces: [NetworkInterfaceInfo], wakeForNetworkAccessEnabled: Bool)
}

/// Encoded video frame for screen streaming
struct ScreenFrame: Codable {
    let data: Data           // H.264 NAL unit data
    let width: Int
    let height: Int
    let timestamp: UInt64    // Presentation timestamp in milliseconds
    let isKeyFrame: Bool     // Whether this is an I-frame (needed for decoder reset)
}

/// Protocol message wrapper with length prefix for TCP framing
struct MessageFrame {
    static func encode<T: Encodable>(_ message: T) throws -> Data {
        let jsonData = try JSONEncoder().encode(message)
        var length = UInt32(jsonData.count).bigEndian
        var frameData = Data(bytes: &length, count: 4)
        frameData.append(jsonData)
        return frameData
    }

    static func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        return try JSONDecoder().decode(type, from: data)
    }
}
