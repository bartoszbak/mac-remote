import Foundation
import AppKit

/// Discovers launchable applications and caches their icons on disk, so the
/// app list is fast after the first scan and survives relaunches.
final class AppCatalog {

    /// Pixel size of icons sent to the client. 48 px renders crisply at the
    /// client's 48 pt grid cell on a 1x display and acceptably on 2x.
    static let iconPixelSize: CGFloat = 48

    private let fileManager = FileManager.default
    private let cacheDirectory: URL
    private var memoryCache: [String: Data] = [:]
    private let lock = NSLock()

    init(cacheDirectory: URL? = nil) {
        let base = cacheDirectory
            ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.pedrocid.MacRemoteServer", isDirectory: true)
        self.cacheDirectory = base.appendingPathComponent("icons", isDirectory: true)
        try? fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
    }

    // MARK: - Discovery

    /// Directories searched for `.app` bundles, in priority order. When the same
    /// bundle identifier appears twice, the first occurrence wins.
    static func applicationDirectories() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var urls = [
            URL(fileURLWithPath: "/Applications"),
            home.appendingPathComponent("Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities")
        ]
        // One level of user-created folders inside /Applications (e.g. "/Applications/Adobe").
        if let children = try? FileManager.default.contentsOfDirectory(
            at: urls[0], includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) {
            for child in children where child.pathExtension != "app" && child.lastPathComponent != "Utilities" {
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    urls.append(child)
                }
            }
        }
        return urls
    }

    /// Scans the application directories. Safe to call off the main thread.
    func installedApps() -> [AppInfo] {
        var seen = Set<String>()
        var apps: [AppInfo] = []

        for directory in Self.applicationDirectories() {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for url in contents where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url),
                      let bundleId = bundle.bundleIdentifier,
                      !seen.contains(bundleId),
                      Self.isLaunchable(bundle) else { continue }
                seen.insert(bundleId)

                let name = Self.displayName(for: bundle, at: url)
                apps.append(AppInfo(name: name, bundleId: bundleId, icon: iconData(for: bundle, at: url)))
            }
        }

        apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        print("[AppCatalog] Found \(apps.count) applications")
        return apps
    }

    /// Background agents and helper apps have nothing to show when launched.
    private static func isLaunchable(_ bundle: Bundle) -> Bool {
        let info = bundle.infoDictionary ?? [:]
        if (info["LSUIElement"] as? Bool) == true || (info["LSUIElement"] as? String) == "1" { return false }
        if (info["LSBackgroundOnly"] as? Bool) == true || (info["LSBackgroundOnly"] as? String) == "1" { return false }
        return true
    }

    private static func displayName(for bundle: Bundle, at url: URL) -> String {
        let fileName = url.deletingPathExtension().lastPathComponent
        // Prefer the localized Finder name; fall back to the bundle's display name, then the file name.
        if let finderName = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName {
            return (finderName as NSString).deletingPathExtension
        }
        return bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? fileName
    }

    // MARK: - Icons

    private func cacheKey(for bundle: Bundle) -> String {
        let id = bundle.bundleIdentifier ?? "unknown"
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
            + "." + (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "")
        let raw = "\(id)@\(version)@\(Int(Self.iconPixelSize))"
        // Keep the file name filesystem-safe.
        return raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
    }

    private func iconData(for bundle: Bundle, at url: URL) -> Data? {
        let key = cacheKey(for: bundle)

        lock.lock()
        if let cached = memoryCache[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let fileURL = cacheDirectory.appendingPathComponent(key).appendingPathExtension("png")
        if let onDisk = try? Data(contentsOf: fileURL) {
            store(onDisk, for: key)
            return onDisk
        }

        let icon = NSWorkspace.shared.icon(forFile: url.path)
        guard let rendered = Self.encodePNG(icon, pixelSize: Self.iconPixelSize) else { return nil }
        try? rendered.write(to: fileURL, options: .atomic)
        store(rendered, for: key)
        return rendered
    }

    private func store(_ data: Data, for key: String) {
        lock.lock()
        memoryCache[key] = data
        lock.unlock()
    }

    /// Removes cached icons from memory and disk.
    func clearCache() {
        lock.lock()
        memoryCache.removeAll()
        lock.unlock()
        try? fileManager.removeItem(at: cacheDirectory)
        try? fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    static func encodePNG(_ image: NSImage, pixelSize: CGFloat) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(pixelSize), pixelsHigh: Int(pixelSize),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: pixelSize, height: pixelSize)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize),
                   from: .zero, operation: .copy, fraction: 1)
        return rep.representation(using: .png, properties: [:])
    }
}
