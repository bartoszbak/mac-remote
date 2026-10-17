import XCTest
@testable import MacRemoteServer

final class RemoteUnlockStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("unlock-token.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testTokenIsAbsentUntilConfiguredAndNotReadFromKeychainFile() {
        let store = RemoteUnlockStore(tokenFileURL: fileURL)
        XCTAssertFalse(store.hasFileToken)
    }

    func testFileTokenIsReturnedAndOwnerOnly() throws {
        let token = PairingCrypto.randomBytes(32)
        try token.write(to: fileURL)
        let store = RemoteUnlockStore(tokenFileURL: fileURL)
        XCTAssertTrue(store.hasFileToken)
        XCTAssertEqual(store.token, token)
    }

    func testShortFileIsIgnored() throws {
        try Data([1, 2, 3]).write(to: fileURL)
        let store = RemoteUnlockStore(tokenFileURL: fileURL)
        XCTAssertFalse(store.hasFileToken)
    }

    func testFormattedPairingKeyGroupsHexInEights() throws {
        try Data(repeating: 0xAB, count: 32).write(to: fileURL)
        let store = RemoteUnlockStore(tokenFileURL: fileURL)
        let key = try XCTUnwrap(store.formattedPairingKey)
        XCTAssertEqual(key.split(separator: "-").count, 8)
        XCTAssertTrue(key.hasPrefix("ABABABAB-"))
    }
}
