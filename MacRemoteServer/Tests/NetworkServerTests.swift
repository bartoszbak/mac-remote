import XCTest
import Network
@testable import MacRemoteServer

/// Loopback tests for framing and connection lifecycle.
final class NetworkServerTests: XCTestCase {

    private var server: NetworkServer!

    override func setUp() {
        super.setUp()
        server = NetworkServer()
    }

    override func tearDown() {
        server.stop()
        server = nil
        super.tearDown()
    }

    /// Starts the server on an ephemeral port and returns that port.
    private func startServer() throws -> UInt16 {
        let running = expectation(description: "server running")
        var port: UInt16 = 0
        server.onStateChanged = { state in
            if case .running(let p) = state, port == 0 {
                port = p
                running.fulfill()
            }
        }
        server.start(port: 0, serviceName: "Test \(UUID().uuidString.prefix(6))")
        wait(for: [running], timeout: 5)
        return port
    }

    private func connect(to port: UInt16) -> NWConnection {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = expectation(description: "client ready")
        connection.stateUpdateHandler = { state in
            if case .ready = state { ready.fulfill() }
        }
        connection.start(queue: .global())
        wait(for: [ready], timeout: 5)
        return connection
    }

    func testValidFrameIsDeliveredAndClientIsTracked() throws {
        let port = try startServer()

        let connected = expectation(description: "client connected callback")
        let received = expectation(description: "message received")
        server.onClientConnected = { _ in connected.fulfill() }
        server.onMessageReceived = { message, _ in
            if case .media(let action) = message, action == .mute { received.fulfill() }
        }

        let client = connect(to: port)
        wait(for: [connected], timeout: 5)

        let frame = try MessageFrame.encode(RemoteMessage.media(action: .mute))
        client.send(content: frame, completion: .contentProcessed { _ in })
        wait(for: [received], timeout: 5)
        client.cancel()
    }

    func testOversizedFrameClosesConnection() throws {
        let port = try startServer()

        let disconnected = expectation(description: "server dropped the client")
        server.onClientDisconnected = { _ in disconnected.fulfill() }
        let never = expectation(description: "no message delivered")
        never.isInverted = true
        server.onMessageReceived = { _, _ in never.fulfill() }

        let client = connect(to: port)

        var length = (NetworkServer.maxInboundFrameLength + 1).bigEndian
        let header = Data(bytes: &length, count: 4)
        client.send(content: header, completion: .contentProcessed { _ in })

        wait(for: [disconnected, never], timeout: 5)
        client.cancel()
    }

    func testZeroLengthFrameClosesConnection() throws {
        let port = try startServer()
        let disconnected = expectation(description: "server dropped the client")
        server.onClientDisconnected = { _ in disconnected.fulfill() }

        let client = connect(to: port)
        client.send(content: Data([0, 0, 0, 0]), completion: .contentProcessed { _ in })
        wait(for: [disconnected], timeout: 5)
        client.cancel()
    }

    func testClientDisconnectIsReported() throws {
        let port = try startServer()
        let connected = expectation(description: "connected")
        let disconnected = expectation(description: "disconnected")
        server.onClientConnected = { _ in connected.fulfill() }
        server.onClientDisconnected = { _ in disconnected.fulfill() }

        let client = connect(to: port)
        wait(for: [connected], timeout: 5)
        client.cancel()
        wait(for: [disconnected], timeout: 5)
    }

    func testStopReportsStoppedState() throws {
        _ = try startServer()
        let stopped = expectation(description: "stopped")
        server.onStateChanged = { state in
            if case .stopped = state { stopped.fulfill() }
        }
        server.stop()
        wait(for: [stopped], timeout: 5)
    }
}
