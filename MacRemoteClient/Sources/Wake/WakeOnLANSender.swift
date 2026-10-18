import Foundation
import Darwin

/// Sends Wake-on-LAN magic packets.
///
/// Two routes, because neither works everywhere:
/// - **Unicast** to the Mac's last known IPv4 address. Needs no special entitlement. It
///   reaches a sleeping Mac when a Bonjour Sleep Proxy (Apple TV, HomePod, another Mac)
///   answers for it, or while the router still remembers the Mac's hardware address.
/// - **Broadcast** to the subnet and to 255.255.255.255, via a socket with SO_BROADCAST.
///   On iOS this needs the multicast networking entitlement; without it the send is
///   refused, which is logged and otherwise harmless.
///
/// Each target gets ports 9 and 7, three times, 300 ms apart.
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
                    var targets: [(host: String, broadcast: Bool)] = []
                    if let address = interface.ipv4Address { targets.append((address, false)) }
                    if let broadcast = interface.ipv4Broadcast { targets.append((broadcast, true)) }
                    targets.append(("255.255.255.255", true))
                    for target in targets {
                        for port in [WakeOnLAN.port, WakeOnLAN.alternatePort] {
                            send(packet, to: target.host, port: port, broadcast: target.broadcast)
                        }
                    }
                }
            }
        }
        print("[Wake] Sent magic packets for \(mac.name) via \(interfaces.map(\.name).joined(separator: ", "))")
        return true
    }

    /// One datagram over a plain UDP socket. Returns the number of bytes sent, or nil.
    @discardableResult
    static func send(_ packet: Data, to host: String, port: UInt16, broadcast: Bool) -> Int? {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        if broadcast {
            var yes: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }

        let sent = packet.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, packet.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 {
            print("[Wake] Send to \(host):\(port) failed: errno \(errno)")
            return nil
        }
        return sent
    }
}
