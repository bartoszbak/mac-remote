import XCTest
@testable import MacRemoteServer

final class AppCatalogTests: XCTestCase {

    private var cacheDir: URL!

    override func setUp() {
        super.setUp()
        cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("AppCatalogTests.\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDir)
        super.tearDown()
    }

    func testApplicationDirectoriesIncludeSystemAndUserLocations() {
        let paths = AppCatalog.applicationDirectories().map(\.path)
        XCTAssertTrue(paths.contains("/Applications"))
        XCTAssertTrue(paths.contains("/System/Applications"))
        XCTAssertTrue(paths.contains("/Applications/Utilities"))
        XCTAssertTrue(paths.contains { $0.hasSuffix("/Applications") && $0.hasPrefix(NSHomeDirectory()) })
    }

    func testScanFindsAppsWithUniqueBundleIdsAndIcons() {
        let catalog = AppCatalog(cacheDirectory: cacheDir)
        let apps = catalog.installedApps()
        XCTAssertFalse(apps.isEmpty)
        XCTAssertEqual(Set(apps.map(\.bundleId)).count, apps.count, "bundle identifiers must be unique")
        XCTAssertTrue(apps.contains { $0.bundleId == "com.apple.Safari" || $0.bundleId == "com.apple.finder" || $0.bundleId == "com.apple.TextEdit" })
        XCTAssertTrue(apps.allSatisfy { $0.icon != nil })
        // Sorted case-insensitively by name.
        let names = apps.map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending })
    }

    func testIconsAreCachedOnDiskAndSecondScanIsFaster() throws {
        let catalog = AppCatalog(cacheDirectory: cacheDir)

        let firstStart = Date()
        let first = catalog.installedApps()
        let firstDuration = Date().timeIntervalSince(firstStart)

        let files = try FileManager.default.contentsOfDirectory(atPath: cacheDir.appendingPathComponent("icons").path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".png") }.count, first.count)

        // A fresh instance must hit the disk cache rather than re-render.
        let secondStart = Date()
        let second = AppCatalog(cacheDirectory: cacheDir).installedApps()
        let secondDuration = Date().timeIntervalSince(secondStart)

        XCTAssertEqual(first.map(\.bundleId), second.map(\.bundleId))
        XCTAssertLessThan(secondDuration, firstDuration, "disk cache should make the second scan faster")
    }

    func testEncodedIconIsPNGOfRequestedSize() throws {
        let image = NSWorkspace.shared.icon(forFile: "/System/Applications/Calculator.app")
        let data = try XCTUnwrap(AppCatalog.encodePNG(image, pixelSize: 48))
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        let decoded = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertEqual(decoded.pixelsWide, 48)
        XCTAssertEqual(decoded.pixelsHigh, 48)
    }
}
