import AppKit

enum InstalledAppsService {
    struct AppInfo: Identifiable, Hashable {
        let bundleIdentifier: String
        let displayName: String
        let icon: NSImage

        var id: String { bundleIdentifier }
    }

    /// Scans standard application directories for .app bundles and returns
    /// a deduplicated, alphabetically sorted list.
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
                let icon = NSWorkspace.shared.icon(forFile: item.path)
                apps.append(AppInfo(bundleIdentifier: bundleId, displayName: name, icon: icon))
            }
        }

        return apps.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
