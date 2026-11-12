import AppKit

enum InstalledAppsService {
    /// Icon edge length used by the app picker. Full-resolution app icons are
    /// up to 1024pt; keeping hundreds of those alive costs tens of megabytes
    /// for rows that render at 20pt.
    private static let iconSize = CGSize(width: 32, height: 32)

    /// Bounded, lazily-populated icon cache keyed by bundle path.
    /// Icons are only ever loaded for rows that actually render.
    private static let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 400
        return cache
    }()

    struct AppInfo: Identifiable, Hashable {
        let bundleIdentifier: String
        let displayName: String
        /// Path to the .app bundle. The icon is loaded from this on demand
        /// rather than eagerly, so discovery does no image work at all.
        let path: String

        var id: String { bundleIdentifier }

        /// Downsampled icon, loaded and cached on first access.
        ///
        /// Deliberately computed: holding an `NSImage` per installed app kept
        /// several hundred full-size icons alive for the lifetime of the
        /// process, for a picker most users open once.
        var icon: NSImage {
            InstalledAppsService.icon(forPath: path)
        }

        static func == (lhs: AppInfo, rhs: AppInfo) -> Bool {
            lhs.bundleIdentifier == rhs.bundleIdentifier
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(bundleIdentifier)
        }
    }

    /// Fetch (and cache) a downsampled icon for an app bundle path.
    static func icon(forPath path: String) -> NSImage {
        let key = path as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        image.size = iconSize
        iconCache.setObject(image, forKey: key)
        return image
    }

    /// Drop every cached icon. Call when the picker closes.
    static func flushIconCache() {
        iconCache.removeAllObjects()
    }

    /// Scans standard application directories for .app bundles and returns
    /// a deduplicated, alphabetically sorted list.
    ///
    /// Safe to call off the main thread: it touches only the file system and
    /// `Bundle`, never AppKit image loading.
    static func discoverInstalledApps() -> [AppInfo] {
        let dirs = [
            "/Applications",
            "/System/Applications",
            "/System/Applications/Utilities",
            NSHomeDirectory() + "/Applications",
        ]

        var seen = Set<String>()
        var apps: [AppInfo] = []

        for dir in dirs {
            let url = URL(fileURLWithPath: dir)
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for item in contents where item.pathExtension == "app" {
                guard let bundle = Bundle(url: item),
                      let bundleId = bundle.bundleIdentifier,
                      !seen.contains(bundleId)
                else { continue }

                seen.insert(bundleId)
                let name = FileManager.default.displayName(atPath: item.path)
                    .replacingOccurrences(of: ".app", with: "")
                apps.append(AppInfo(bundleIdentifier: bundleId, displayName: name, path: item.path))
            }
        }

        return apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
