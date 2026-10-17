import Foundation
import Darwin
import AppKit
import IOKit.ps

/// Enumerates the Mac's wake-capable network interfaces.
enum NetworkInterfaces {

    /// Active Ethernet/Wi-Fi interfaces (`en*`) that are up and have an IPv4 address.
    static func active() -> [NetworkInterfaceInfo] {
        var addresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addresses) == 0, let first = addresses else { return [] }
        defer { freeifaddrs(addresses) }

        var hardware: [String: String] = [:]
        var ipv4: [String: (address: String, broadcast: String?)] = [:]
        var upInterfaces = Set<String>()

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("en"), let addr = entry.pointee.ifa_addr else { continue }
            let flags = Int32(entry.pointee.ifa_flags)
            if flags & IFF_UP != 0 && flags & IFF_RUNNING != 0 { upInterfaces.insert(name) }

            switch Int32(addr.pointee.sa_family) {
            case AF_LINK:
                addr.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link in
                    let dl = link.pointee
                    guard dl.sdl_alen == 6 else { return }
                    withUnsafePointer(to: dl.sdl_data) { dataPtr in
                        dataPtr.withMemoryRebound(to: UInt8.self, capacity: Int(dl.sdl_nlen) + 6) { bytes in
                            let mac = (0..<6).map { bytes[Int(dl.sdl_nlen) + $0] }
                            guard mac.contains(where: { $0 != 0 }) else { return }
                            hardware[name] = WakeOnLAN.formatHardwareAddress(mac)
                        }
                    }
                }
            case AF_INET:
                let address = ipv4String(addr)
                var broadcast: String?
                if flags & IFF_BROADCAST != 0, let dst = entry.pointee.ifa_dstaddr {
                    broadcast = ipv4String(dst)
                }
                if let address { ipv4[name] = (address, broadcast) }
            default:
                break
            }
        }

        return hardware.keys.sorted().compactMap { name in
            guard upInterfaces.contains(name), let mac = hardware[name], let ip = ipv4[name] else { return nil }
            return NetworkInterfaceInfo(name: name, hardwareAddress: mac, ipv4Address: ip.address, ipv4Broadcast: ip.broadcast)
        }
    }

    private static func ipv4String(_ addr: UnsafeMutablePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        return addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
            var address = sin.pointee.sin_addr
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            return String(cString: buffer)
        }
    }
}

/// Reads the "Wake for network access" power setting.
enum WakeSettings {

    /// True when the active power profile has Wake On LAN ("womp") enabled.
    /// Reads `pmset -g`, which reports the settings in effect for the current power source.
    static var isWakeForNetworkAccessEnabled: Bool {
        guard let output = run("/usr/bin/pmset", ["-g"]) else { return false }
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "womp" {
                return parts[1] == "1"
            }
        }
        return false
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    static var hasBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return !list.isEmpty
    }

    /// Opens Battery (laptops) or Energy (desktops) settings, where the toggle lives.
    static func openEnergySettings() {
        let pane = hasBattery ? "com.apple.Battery-Settings.extension" : "com.apple.Energy-Saver-Settings.extension"
        if let url = URL(string: "x-apple.systempreferences:\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
