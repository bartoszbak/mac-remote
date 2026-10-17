import XCTest
import Network
@testable import MacRemoteServer

/// Loopback tests for the encrypted listener with per-device pre-shared keys.
final class NetworkServerTLSTests: XCTestCase {

    private var server: NetworkServer!
    private let keyA = PairingCrypto.randomBytes(32)
    private let keyB = PairingCrypto.randomBytes(32)

    override func setUp() {
        super.setUp()
        server = NetworkServer()
    }

    override func tearDown() {
        server.stop()
        server = nil
        super.tearDown()
    }

    private func startSecureServer() throws -> UInt16 {
        let running = expectation(description: "server running")
        var port: UInt16 = 0
        server.onStateChanged = { state in
            if case .running(let p) = state, port == 0 {
                port = p
                running.fulfill()
            }
        }
        server.start(port: 0, serviceName: nil, tls: .init(presharedKeys: [
            .init(identity: "device-a", key: keyA),
            .init(identity: "device-b", key: keyB)
        ]))
        wait(for: [running], timeout: 5)
        XCTAssertTrue(server.isSecure)
        return port
    }

    private func connect(port: UInt16, identity: String, key: Data) -> (NWConnection, XCTestExpectation, XCTestExpectation) {
        let tcp = NWProtocolTCP.Options()
        let parameters = NWParameters(tls: NetworkServer.clientTLSOptions(identity: identity, key: key), tcp: tcp)
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: parameters)
        let ready = expectation(description: "client ready \(identity)")
        // A rejected TLS handshake surfaces as `.waiting` (with retries) or `.failed`.
        let failed = expectation(description: "client not accepted \(identity)")
        failed.assertForOverFulfill = false
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.fulfill()
            case .waiting, .failed: failed.fulfill()
            default: break
            }
        }
        connection.start(queue: .global())
        return (connection, ready, failed)
    }

    func testSecondRegisteredIdentityCanConnectAndSend() throws {
        let port = try startSecureServer()

        let received = expectation(description: "message received")
        server.onMessageReceived = { message, _ in
            if case .hello(let id, _, _) = message, id == "device-b" { received.fulfill() }
        }

        let (client, ready, failed) = connect(port: port, identity: "device-b", key: keyB)
        failed.isInverted = true
        wait(for: [ready], timeout: 5)

        let frame = try MessageFrame.encode(RemoteMessage.hello(deviceID: "device-b", deviceName: "B", protocolVersion: 2))
        client.send(content: frame, completion: .contentProcessed { _ in })
        wait(for: [received, failed], timeout: 5)
        client.cancel()
    }

    func testFirstRegisteredIdentityCanConnect() throws {
        let port = try startSecureServer()
        let connected = expectation(description: "server saw client")
        server.onClientConnected = { _ in connected.fulfill() }

        let (client, ready, failed) = connect(port: port, identity: "device-a", key: keyA)
        failed.isInverted = true
        wait(for: [ready, connected, failed], timeout: 5)
        client.cancel()
    }

    func testWrongKeyCannotCompleteHandshake() throws {
        let port = try startSecureServer()
        let never = expectation(description: "server never reports a ready client")
        never.isInverted = true
        server.onClientConnected = { _ in never.fulfill() }

        let (client, ready, failed) = connect(port: port, identity: "device-a", key: PairingCrypto.randomBytes(32))
        ready.isInverted = true
        wait(for: [ready, failed, never], timeout: 5)
        client.cancel()
    }

    func testUnknownIdentityCannotCompleteHandshake() throws {
        let port = try startSecureServer()
        let never = expectation(description: "server never reports a ready client")
        never.isInverted = true
        server.onClientConnected = { _ in never.fulfill() }

        let (client, ready, failed) = connect(port: port, identity: "device-z", key: keyA)
        ready.isInverted = true
        wait(for: [ready, failed, never], timeout: 5)
        client.cancel()
    }

    func testPlaintextClientIsRejectedByTLSListener() throws {
        let port = try startSecureServer()
        let never = expectation(description: "no plaintext message delivered")
        never.isInverted = true
        server.onMessageReceived = { _, _ in never.fulfill() }

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = expectation(description: "tcp connected")
        client.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        client.start(queue: .global())
        wait(for: [ready], timeout: 5)

        let frame = try MessageFrame.encode(RemoteMessage.ping)
        client.send(content: frame, completion: .contentProcessed { _ in })
        // Nothing sent in plaintext may ever come back as a protocol reply.
        let noReply = expectation(description: "no plaintext reply")
        noReply.isInverted = true
        client.receive(minimumIncompleteLength: 4, maximumLength: 4) { data, _, _, _ in
            if let data, data.count == 4 {
                let length = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
                if length > 0, length < 1024 { noReply.fulfill() }
            }
        }
        wait(for: [never, noReply], timeout: 3)
        client.cancel()
    }
}
