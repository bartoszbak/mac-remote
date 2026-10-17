import XCTest
@testable import MacRemoteServer

final class WakeOnLANTests: XCTestCase {

    func testParsesCommonHardwareAddressFormats() {
        let expected: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        XCTAssertEqual(WakeOnLAN.parseHardwareAddress("aa:bb:cc:dd:ee:ff"), expected)
        XCTAssertEqual(WakeOnLAN.parseHardwareAddress("AA-BB-CC-DD-EE-FF"), expected)
        XCTAssertEqual(WakeOnLAN.parseHardwareAddress("aabbccddeeff"), expected)
        XCTAssertNil(WakeOnLAN.parseHardwareAddress("aa:bb:cc:dd:ee"))
        XCTAssertNil(WakeOnLAN.parseHardwareAddress("zz:bb:cc:dd:ee:ff"))
    }

    func testFormatRoundTrips() {
        let text = "01:23:45:67:89:ab"
        XCTAssertEqual(WakeOnLAN.formatHardwareAddress(WakeOnLAN.parseHardwareAddress(text)!), text)
    }

    func testMagicPacketLayout() throws {
        let packet = try XCTUnwrap(WakeOnLAN.magicPacket(hardwareAddress: "01:23:45:67:89:ab"))
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), [UInt8](repeating: 0xFF, count: 6))
        let mac: [UInt8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB]
        for repetition in 0..<16 {
            let start = 6 + repetition * 6
            XCTAssertEqual(Array(packet[start..<start + 6]), mac, "repetition \(repetition)")
        }
        XCTAssertNil(WakeOnLAN.magicPacket(hardwareAddress: "nope"))
    }

    func testActiveInterfacesHaveValidAddresses() {
        let interfaces = NetworkInterfaces.active()
        // CI runners and laptops always have at least one en* interface up.
        XCTAssertFalse(interfaces.isEmpty)
        for interface in interfaces {
            XCTAssertTrue(interface.name.hasPrefix("en"))
            XCTAssertNotNil(WakeOnLAN.parseHardwareAddress(interface.hardwareAddress), interface.hardwareAddress)
            XCTAssertNotNil(interface.ipv4Address)
        }
    }

    func testWakeSettingReadsWithoutCrashing() {
        _ = WakeSettings.isWakeForNetworkAccessEnabled
        _ = WakeSettings.hasBattery
    }
}
