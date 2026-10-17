import XCTest
@testable import MacRemoteServer

@MainActor
final class AppSettingsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaults() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.autoStartServer)
        XCTAssertFalse(settings.hasCompletedOnboarding)
        XCTAssertTrue(settings.showCursorInStream)
        XCTAssertEqual(settings.sharedDisplayID, 0)
        XCTAssertEqual(settings.effectivePort, NetworkConstants.defaultPort)
        XCTAssertEqual(settings.effectiveServiceName, AppSettings.defaultServiceName)
    }

    func testValuesPersistAcrossInstances() {
        let first = AppSettings(defaults: defaults)
        first.autoStartServer = false
        first.serviceName = "Studio Mac"
        first.port = 6000
        first.hasCompletedOnboarding = true
        first.sharedDisplayID = 69_733_382

        let second = AppSettings(defaults: defaults)
        XCTAssertFalse(second.autoStartServer)
        XCTAssertEqual(second.serviceName, "Studio Mac")
        XCTAssertEqual(second.port, 6000)
        XCTAssertTrue(second.hasCompletedOnboarding)
        XCTAssertEqual(second.sharedDisplayID, 69_733_382)
    }

    func testEffectivePortIsClampedToValidRange() {
        let settings = AppSettings(defaults: defaults)
        settings.port = 0
        XCTAssertEqual(settings.effectivePort, 1)
        settings.port = 99_999
        XCTAssertEqual(settings.effectivePort, 65535)
    }

    func testBlankServiceNameFallsBackToHostName() {
        let settings = AppSettings(defaults: defaults)
        settings.serviceName = "   "
        XCTAssertEqual(settings.effectiveServiceName, AppSettings.defaultServiceName)
        settings.serviceName = "  Desk  "
        XCTAssertEqual(settings.effectiveServiceName, "Desk")
    }
}
