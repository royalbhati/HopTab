import AppKit

struct PinnedApp: Codable, Identifiable, Equatable, Hashable {
    let bundleIdentifier: String
    let displayName: String
    var sortOrder: Int
    /// Display name (NSScreen.localizedName) to place this app's windows on, or nil for no preference.
    var assignedDisplay: String?

    var id: String { bundleIdentifier }

    // MARK: - Computed (not persisted)

    var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: displayName)
            ?? NSImage()
    }

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
