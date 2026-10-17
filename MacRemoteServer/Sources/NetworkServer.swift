import Foundation
import Network

/// TCP server that accepts client connections, advertises itself over Bonjour
/// and delivers decoded `RemoteMessage`s.
///
/// All mutable state is confined to `queue`. Every callback is delivered on the
/// main queue so callers can update UI directly.
final class NetworkServer {

    enum State: Equatable {
        case stopped
        case starting
        case running(port: UInt16)
        case failed(Failure)
    }

    enum Failure: Equatable, LocalizedError {
        case portInUse(UInt16)
        case other(String)

        var errorDescription: String? {
            switch self {
            case .portInUse(let port):
                return String(localized: "Port \(port) is already in use.")
            case .other(let message):
                return message
            }
        }
    }

    /// Control messages from the client are tiny; anything bigger is hostile or corrupt.
    static let maxInboundFrameLength: UInt32 = 64 * 1024

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let queue = DispatchQueue(label: "com.macremote.server", qos: .userInteractive)

    // Callbacks, always invoked on the main queue.
    var onStateChanged: ((State) -> Void)?
    var onAdvertisedNameChanged: ((String?) -> Void)?
    var onClientConnected: ((NWConnection) -> Void)?
    var onClientDisconnected: ((NWConnection) -> Void)?
    var onMessageReceived: ((RemoteMessage, NWConnection) -> Void)?

    // MARK: - Lifecycle

    func start(port: UInt16, serviceName: String) {
        queue.async { [self] in
            guard listener == nil else { return }

            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.noDelay = true
            tcpOptions.enableKeepalive = true
            tcpOptions.keepaliveIdle = 5
            tcpOptions.keepaliveInterval = 5
            tcpOptions.keepaliveCount = 3

            let parameters = NWParameters(tls: nil, tcp: tcpOptions)
            parameters.allowLocalEndpointReuse = true
            parameters.includePeerToPeer = true

            let newListener: NWListener
            do {
                newListener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port) ?? .any)
            } catch {
                notify(.failed(.other(error.localizedDescription)))
                return
            }

            newListener.service = NWListener.Service(name: serviceName, type: NetworkConstants.serviceType)

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .setup, .waiting:
                    self.notify(.starting)
                case .ready:
                    let actualPort = self.listener?.port?.rawValue ?? port
                    print("[Server] Listening on port \(actualPort)")
                    self.notify(.running(port: actualPort))
                case .failed(let error):
                    print("[Server] Listener failed: \(error)")
                    self.tearDown()
                    if case .posix(let code) = error, code == .EADDRINUSE {
                        self.notify(.failed(.portInUse(port)))
                    } else {
                        self.notify(.failed(.other(error.localizedDescription)))
                    }
                case .cancelled:
                    self.notify(.stopped)
                @unknown default:
                    break
                }
            }

            newListener.serviceRegistrationUpdateHandler = { [weak self] change in
                guard let self else { return }
                switch change {
                case .add(let endpoint):
                    if case .service(let name, _, _, _) = endpoint {
                        print("[Bonjour] Advertising as \(name)")
                        DispatchQueue.main.async { self.onAdvertisedNameChanged?(name) }
                    }
                case .remove:
                    DispatchQueue.main.async { self.onAdvertisedNameChanged?(nil) }
                @unknown default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }

            listener = newListener
            notify(.starting)
            newListener.start(queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            tearDown()
            notify(.stopped)
        }
    }

    /// Must be called on `queue`.
    private func tearDown() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        let open = connections
        connections.removeAll()
        for connection in open {
            connection.cancel()
            DispatchQueue.main.async { [weak self] in self?.onClientDisconnected?(connection) }
        }
    }

    private func notify(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onStateChanged?(state) }
    }

    // MARK: - Sending

    func send(_ message: ServerMessage, to connection: NWConnection) {
        let data: Data
        do {
            data = try MessageFrame.encode(message)
        } catch {
            print("[Server] Encode error: \(error)")
            return
        }
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                print("[Server] Send error: \(error)")
            }
        })
    }

    func sendToConnections(_ message: ServerMessage, matching predicate: @escaping (NWConnection) -> Bool) {
        let data: Data
        do {
            data = try MessageFrame.encode(message)
        } catch {
            print("[Server] Encode error: \(error)")
            return
        }
        queue.async { [self] in
            for connection in connections where predicate(connection) {
                connection.send(content: data, completion: .contentProcessed { error in
                    if let error {
                        print("[Server] Send error: \(error)")
                    }
                })
            }
        }
    }

    // MARK: - Connections (queue-confined)

    private func accept(_ connection: NWConnection) {
        print("[Server] New connection from \(connection.endpoint)")
        connections.append(connection)

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                print("[Server] Client connected: \(connection.endpoint)")
                DispatchQueue.main.async { self.onClientConnected?(connection) }
                self.receiveFrame(from: connection)
            case .failed(let error):
                print("[Server] Connection failed: \(error)")
                self.remove(connection)
            case .cancelled:
                self.remove(connection)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func remove(_ connection: NWConnection) {
        let before = connections.count
        connections.removeAll { $0 === connection }
        guard connections.count != before else { return }
        print("[Server] Client disconnected: \(connection.endpoint)")
        DispatchQueue.main.async { [weak self] in self?.onClientDisconnected?(connection) }
    }

    private func close(_ connection: NWConnection, reason: String) {
        print("[Server] Closing connection: \(reason)")
        connection.cancel()
    }

    private func receiveFrame(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                self.close(connection, reason: "receive error \(error)")
                return
            }
            guard let lengthData = data, lengthData.count == 4 else {
                if isComplete {
                    self.close(connection, reason: "peer closed")
                } else {
                    self.receiveFrame(from: connection)
                }
                return
            }

            let length = lengthData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
            guard length > 0, length <= Self.maxInboundFrameLength else {
                self.close(connection, reason: "invalid frame length \(length)")
                return
            }

            connection.receive(minimumIncompleteLength: Int(length), maximumLength: Int(length)) { [weak self] payload, _, isComplete, error in
                guard let self else { return }

                if let error {
                    self.close(connection, reason: "receive error \(error)")
                    return
                }
                guard let payload, payload.count == Int(length) else {
                    self.close(connection, reason: isComplete ? "peer closed mid-frame" : "short frame")
                    return
                }

                do {
                    let message = try MessageFrame.decode(payload, as: RemoteMessage.self)
                    DispatchQueue.main.async { self.onMessageReceived?(message, connection) }
                } catch {
                    print("[Server] Decode error: \(error)")
                }

                self.receiveFrame(from: connection)
            }
        }
    }
}

extension NWConnection {
    /// Best-effort human readable peer address, e.g. "192.168.1.23".
    var peerDescription: String {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let address):
                return address.debugDescription
            case .ipv6(let address):
                return address.debugDescription
            case .name(let name, _):
                return name
            @unknown default:
                return host.debugDescription
            }
        default:
            return endpoint.debugDescription
        }
    }
}
