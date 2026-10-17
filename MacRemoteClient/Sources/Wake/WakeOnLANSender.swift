import Foundation
import Network

/// Sends Wake-on-LAN magic packets over UDP broadcast.
///
/// Each wakeable interface gets a packet to its subnet broadcast address and to
/// 255.255.255.255, on port 9 and port 7, repeated three times 300 ms apart. That is
/// twelve small datagrams per interface; the Mac only needs one of them to arrive.
enum WakeOnLANSender {

    private static let repeats = 3
    private static let interval: TimeInterval = 0.3
    private static let queue = DispatchQueue(label: "com.macremote.wake", qos: .userInitiated)

    /// Returns false when the Mac has nothing a magic packet could target.
    @discardableResult
    static func wake(_ mac: KnownMac) -> Bool {
        let interfaces = mac.wakeableInterfaces
        guard !interfaces.isEmpty else { return false }

        for attempt in 0..<repeats {
            queue.asyncAfter(deadline: .now() + interval * Double(attempt)) {
                for interface in interfaces {
                    guard let packet = WakeOnLAN.magicPacket(hardwareAddress: interface.hardwareAddress) else { continue }
                    var hosts = ["255.255.255.255"]
                    if let broadcast = interface.ipv4Broadcast { hosts.insert(broadcast, at: 0) }
                    for host in hosts {
                        for port in [WakeOnLAN.port, WakeOnLAN.alternatePort] {
                            send(packet, to: host, port: port)
                        }
                    }
                }
            }
        }
        print("[Wake] Sent magic packets for \(mac.name) via \(interfaces.map(\.name).joined(separator: ", "))")
        return true
    }

    private static func send(_ packet: Data, to host: String, port: UInt16) {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: packet, completion: .contentProcessed { error in
                    if let error {
                        print("[Wake] Send to \(host):\(port) failed: \(error)")
                    }
                    connection.cancel()
                })
            case .failed(let error):
                print("[Wake] Connection to \(host):\(port) failed: \(error)")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        // Never leave a datagram socket open if the network stays silent.
        queue.asyncAfter(deadline: .now() + 2) { connection.cancel() }
    }
}
