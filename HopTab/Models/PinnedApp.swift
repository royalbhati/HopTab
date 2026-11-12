import AppKit

struct PinnedApp: Codable, Identifiable, Equatable, Hashable {
    let bundleIdentifier: String
    let displayName: String
    var sortOrder: Int
    /// Display name (NSScreen.localizedName) to place this app's windows on, or nil for no preference.
    var assignedDisplay: String?

    var id: String { bundleIdentifier }

    // MARK: - Computed (not persisted)

    /// App icon, cached per bundle identifier. The switcher overlay renders
    /// every tile's icon on each open; resolving the bundle URL and loading
    /// the icon each time was a visible part of the open delay.
    var icon: NSImage {
        let key = bundleIdentifier as NSString
        if let cached = Self.iconCache.object(forKey: key) { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            image = NSWorkspace.shared.icon(forFile: url.path)
        } else {
            image = NSImage(systemSymbolName: "app.fill", accessibilityDescription: displayName) ?? NSImage()
        }
        Self.iconCache.setObject(image, forKey: key)
        return image
    }

    private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 200
        return cache
    }()

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    var runningApplication: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }
}
