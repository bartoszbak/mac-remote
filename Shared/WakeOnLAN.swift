import Foundation

/// A network interface on the Mac that a client can send a Wake-on-LAN packet to.
struct NetworkInterfaceInfo: Codable, Equatable, Hashable {
    let name: String              // e.g. "en0"
    let hardwareAddress: String   // "aa:bb:cc:dd:ee:ff"
    let ipv4Address: String?
    let ipv4Broadcast: String?    // subnet broadcast, best target for the magic packet
}

/// Wake-on-LAN magic packet construction. Shared so both apps agree on the format.
///
/// The Mac must have "Wake for network access" enabled (System Settings → Energy /
/// Battery). Send the packet as a UDP broadcast to `ipv4Broadcast` (or
/// 255.255.255.255) on port 9; many setups also accept port 7.
enum WakeOnLAN {

    static let port: UInt16 = 9
    static let alternatePort: UInt16 = 7

    /// Parses "aa:bb:cc:dd:ee:ff", "AA-BB-CC-DD-EE-FF" or "aabbccddeeff".
    static func parseHardwareAddress(_ text: String) -> [UInt8]? {
        let hex = text.filter(\.isHexDigit)
        guard hex.count == 12 else { return nil }
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return bytes
    }

    static func formatHardwareAddress(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// 6 bytes of 0xFF followed by the hardware address repeated 16 times.
    static func magicPacket(hardwareAddress: String) -> Data? {
        guard let mac = parseHardwareAddress(hardwareAddress) else { return nil }
        var packet = Data(repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: mac) }
        return packet
    }
}
