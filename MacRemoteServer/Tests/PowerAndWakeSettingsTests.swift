import XCTest
import IOKit.pwr_mgt
@testable import MacRemoteServer

final class PowerAndWakeSettingsTests: XCTestCase {

    /// Captured from a MacBook with wake on power only.
    private let laptopOutput = """
    Battery Power:
     Sleep On Power Button 1
     powernap             1
     womp                 0
     sleep                1
    AC Power:
     Sleep On Power Button 1
     powernap             1
     womp                 1
     sleep                0
    """

    func testParsesBothProfilesIndependentOfCurrentSource() {
        let profile = WakeSettings.parse(customOutput: laptopOutput)
        XCTAssertEqual(profile, WakeSettings.Profile(onPower: true, onBattery: false))
    }

    func testDesktopHasNoBatteryProfile() {
        let desktop = """
        AC Power:
         womp                 1
        """
        XCTAssertEqual(WakeSettings.parse(customOutput: desktop), WakeSettings.Profile(onPower: true, onBattery: nil))
    }

    func testMissingOutputMeansNoWake() {
        XCTAssertEqual(WakeSettings.parse(customOutput: ""), WakeSettings.Profile(onPower: false, onBattery: nil))
    }

    func testLiveProfileReads() {
        // This Mac's real settings; just must not crash and must agree with itself.
        let profile = WakeSettings.profile
        XCTAssertEqual(WakeSettings.isWakeForNetworkAccessEnabled, profile.onPower)
    }

    func testKeepAwakeAssertionIsCreatedAndReleased() throws {
        let power = PowerAssertions()
        power.setKeepAwake(true)
        XCTAssertTrue(power.isKeepingAwake)
        XCTAssertTrue(try ownAssertionNames().contains(PowerAssertions.keepAwakeName as String))

        power.setKeepAwake(false)
        XCTAssertFalse(power.isKeepingAwake)
        XCTAssertFalse(try ownAssertionNames().contains(PowerAssertions.keepAwakeName as String))
    }

    func testDeclareUserActivitySucceeds() {
        XCTAssertTrue(PowerAssertions().declareUserActivity())
    }

    /// Names of the power assertions held by this test process.
    private func ownAssertionNames() throws -> [String] {
        var unmanaged: Unmanaged<CFDictionary>?
        XCTAssertEqual(IOPMCopyAssertionsByProcess(&unmanaged), kIOReturnSuccess)
        let byPID = try XCTUnwrap(unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]])
        let mine = byPID[NSNumber(value: getpid())] ?? []
        return mine.compactMap { $0[kIOPMAssertionNameKey as String] as? String }
    }
}
