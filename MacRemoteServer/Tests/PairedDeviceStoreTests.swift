import XCTest
@testable import MacRemoteServer

final class PairedDeviceStoreTests: XCTestCase {

    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("PairedDeviceStoreTests.\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func device(_ id: String, name: String) -> PairedDevice {
        PairedDevice(id: id, name: name, presharedKey: PairingCrypto.randomBytes(32), pairedAt: Date(), lastSeen: nil)
    }

    func testStartsEmpty() {
        XCTAssertTrue(PairedDeviceStore(fileURL: fileURL).devices.isEmpty)
    }

    func testUpsertRenameTouchRemovePersistAcrossInstances() throws {
        let store = PairedDeviceStore(fileURL: fileURL)
        let phone = device("A", name: "Phone")
        store.upsert(phone)
        store.upsert(device("B", name: "Tablet"))
        store.rename(id: "A", to: "Bart's iPhone")
        store.touch(id: "B")

        let reloaded = PairedDeviceStore(fileURL: fileURL)
        XCTAssertEqual(reloaded.devices.map(\.id), ["A", "B"])
        XCTAssertEqual(reloaded.device(id: "A")?.name, "Bart's iPhone")
        XCTAssertEqual(reloaded.device(id: "A")?.presharedKey, phone.presharedKey)
        XCTAssertNotNil(reloaded.device(id: "B")?.lastSeen)

        reloaded.remove(id: "A")
        XCTAssertEqual(PairedDeviceStore(fileURL: fileURL).devices.map(\.id), ["B"])
    }

    func testUpsertReplacesExistingDeviceWithSameID() {
        let store = PairedDeviceStore(fileURL: fileURL)
        store.upsert(device("A", name: "One"))
        store.upsert(device("A", name: "Two"))
        XCTAssertEqual(store.devices.count, 1)
        XCTAssertEqual(store.devices.first?.name, "Two")
    }

    func testFileIsOwnerReadableOnly() throws {
        let store = PairedDeviceStore(fileURL: fileURL)
        store.upsert(device("A", name: "Phone"))
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? Int)
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    func testCorruptFileIsTreatedAsEmpty() throws {
        try Data("not json".utf8).write(to: fileURL)
        XCTAssertTrue(PairedDeviceStore(fileURL: fileURL).devices.isEmpty)
    }
}
