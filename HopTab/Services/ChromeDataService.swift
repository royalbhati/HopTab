import AppKit
import Foundation
import SQLite3

/// Reads Google Chrome's local data for the command palette.
///
/// Three sources, three mechanisms:
/// - **Profiles, bookmarks**: plain JSON under Chrome's Application Support
///   directory. Read directly.
/// - **History**: a SQLite database Chrome keeps locked while it runs. Copied
///   to a temp file first, then queried from the copy.
/// - **Open tabs**: live, via Apple Events to Chrome (`osascript`). The first
///   call triggers the macOS Automation prompt for HopTab → Google Chrome.
///
/// Every reader is safe off the main thread and returns an empty array when
/// Chrome is not installed or a file is missing. Nothing here launches Chrome.
enum ChromeDataService {
    static let bundleIdentifier = "com.google.Chrome"

    static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    static var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return InstalledAppsService.icon(forPath: url.path)
    }

    // MARK: - Profiles

    struct ChromeProfile: Equatable, Hashable {
        /// Directory name Chrome uses on disk and on the command line
        /// (`Default`, `Profile 2`…).
        let directory: String
        /// What the user sees in Chrome's profile menu.
        let name: String
    }

    /// Profiles from `Local State` → `profile.info_cache`. Sorted by name.
    static func profiles() -> [ChromeProfile] {
        let url = supportDirectory.appendingPathComponent("Local State")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: Any]
        else { return [] }

        return cache.compactMap { key, value -> ChromeProfile? in
            guard let info = value as? [String: Any] else { return nil }
            let name = (info["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (info["gaia_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? key
            return ChromeProfile(directory: key, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Bookmarks

    struct Bookmark: Equatable {
        let title: String
        let url: URL
        let profile: ChromeProfile
    }

    static func bookmarks(for profile: ChromeProfile) -> [Bookmark] {
        let url = supportDirectory.appendingPathComponent(profile.directory).appendingPathComponent("Bookmarks")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = root["roots"] as? [String: Any]
        else { return [] }

        var out: [Bookmark] = []
        func walk(_ node: [String: Any]) {
            if let type = node["type"] as? String, type == "url",
               let urlString = node["url"] as? String,
               let url = URL(string: urlString),
               url.scheme == "http" || url.scheme == "https" {
                let title = (node["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url.host ?? urlString
                out.append(Bookmark(title: title, url: url, profile: profile))
            }
            if let children = node["children"] as? [[String: Any]] {
                children.forEach(walk)
            }
        }
        for (_, value) in roots {
            if let node = value as? [String: Any] { walk(node) }
        }
        return out
    }

    // MARK: - History

    struct HistoryEntry: Equatable {
        let title: String
        let url: URL
        let visitCount: Int
        /// Seconds since 1970.
        let lastVisit: TimeInterval
        let profile: ChromeProfile
    }

    /// Most recent `limit` URLs from the profile's History database.
    ///
    /// Chrome holds the file open with an exclusive lock, so it is copied to
    /// the temp directory and the copy is opened read-only. Local
    /// `chrome://`, `file://` and search-redirect rows are dropped.
    static func history(for profile: ChromeProfile, days: Int = 30, limit: Int = 2000) -> [HistoryEntry] {
        let source = supportDirectory.appendingPathComponent(profile.directory).appendingPathComponent("History")
        guard FileManager.default.fileExists(atPath: source.path) else { return [] }

        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoptab-chrome-history-\(profile.directory.replacingOccurrences(of: " ", with: "_"))-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            try FileManager.default.copyItem(at: source, to: temp)
        } catch {
            return []
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }

        // Chrome stores microseconds since 1601-01-01.
        let chromeEpochOffset: Int64 = 11_644_473_600
        let cutoff = (Int64(Date().timeIntervalSince1970) - Int64(days) * 86_400 + chromeEpochOffset) * 1_000_000

        let sql = """
        SELECT url, title, visit_count, last_visit_time
        FROM urls
        WHERE last_visit_time > ? AND hidden = 0
        ORDER BY last_visit_time DESC
        LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, cutoff)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var out: [HistoryEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let urlC = sqlite3_column_text(stmt, 0) else { continue }
            let urlString = String(cString: urlC)
            guard let url = URL(string: urlString), url.scheme == "http" || url.scheme == "https" else { continue }
            let title = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let visits = Int(sqlite3_column_int(stmt, 2))
            let last = sqlite3_column_int64(stmt, 3)
            let seconds = TimeInterval(last / 1_000_000 - chromeEpochOffset)
            out.append(HistoryEntry(
                title: title.isEmpty ? (url.host ?? urlString) : title,
                url: url,
                visitCount: max(visits, 1),
                lastVisit: seconds,
                profile: profile
            ))
        }
        return out
    }

    // MARK: - Open tabs (Apple Events)

    struct OpenTab: Equatable {
        /// 1-based, front-to-back, as Chrome's scripting dictionary orders windows.
        let windowIndex: Int
        /// 1-based position in the window's tab strip.
        let tabIndex: Int
        let title: String
        let url: URL?
        let isActive: Bool
    }

    /// Every tab in every Chrome window. Empty when Chrome is not running
    /// (never launches it) or when Automation access was denied.
    static func openTabs() -> [OpenTab] {
        guard isRunning else { return [] }
        let script = """
        tell application "Google Chrome"
            set out to ""
            set wi to 0
            repeat with w in windows
                set wi to wi + 1
                set ai to active tab index of w
                set ti to 0
                repeat with t in tabs of w
                    set ti to ti + 1
                    set out to out & wi & tab & ti & tab & (ai = ti) & tab & (URL of t) & tab & (title of t) & linefeed
                end repeat
            end repeat
            return out
        end tell
        """
        guard let output = runAppleScript(script) else { return [] }
        return output.split(separator: "\n").compactMap { line -> OpenTab? in
            let parts = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard parts.count == 5, let wi = Int(parts[0]), let ti = Int(parts[1]) else { return nil }
            let url = URL(string: String(parts[3]))
            var title = String(parts[4])
            if title.isEmpty { title = url?.host ?? "Untitled" }
            return OpenTab(windowIndex: wi, tabIndex: ti, title: title, url: url, isActive: parts[2] == "true")
        }
    }

    /// Bring a tab to the front: select it in its window, raise that window,
    /// activate Chrome.
    static func activateTab(windowIndex: Int, tabIndex: Int) {
        let script = """
        tell application "Google Chrome"
            set active tab index of window \(windowIndex) to \(tabIndex)
            set index of window \(windowIndex) to 1
            activate
        end tell
        """
        _ = runAppleScript(script)
    }

    /// Bring a profile's window to the front, opening one only if it has
    /// none. With more than one profile Chrome titles every window
    /// "Page – Google Chrome – Person (Profile)", so an existing window is
    /// found by that suffix through Accessibility and raised in place.
    /// Returns true when an existing window was raised.
    @discardableResult
    static func switchToProfile(directory: String, name: String) -> Bool {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first {
            let windows = AppSwitcherService.enumerateWindows(of: app)
            if let match = windows.first(where: { windowTitle($0.title, belongsToProfileNamed: name) }) {
                // Activation raises the app's current key window; let that
                // settle, then raise the profile's window on top of it.
                app.activate(options: .activateIgnoringOtherApps)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    AppSwitcherService.raiseWindow(of: app, windowID: match.id)
                }
                return true
            }
        }
        // No window for this profile: ask Chrome to open one. The running
        // instance receives the request, so this never starts a second copy.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-na", "Google Chrome", "--args", "--profile-directory=\(directory)"]
        try? process.run()
        return false
    }

    /// "Inbox – Google Chrome – Royal (M)" belongs to profile "M";
    /// "Inbox – Google Chrome – z" belongs to profile "z".
    static func windowTitle(_ title: String, belongsToProfileNamed name: String) -> Bool {
        guard let range = title.range(of: "Google Chrome", options: .backwards) else { return false }
        let tail = title[range.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " –-—"))
        guard !tail.isEmpty else { return false }
        return tail == name || tail.hasSuffix("(\(name))")
    }

    /// Close a tab. Used by ⌘⌫ in the palette.
    static func closeTab(windowIndex: Int, tabIndex: Int) {
        _ = runAppleScript("""
        tell application "Google Chrome" to close tab \(tabIndex) of window \(windowIndex)
        """)
    }

    /// Open a URL in a specific Chrome profile (new tab in that profile's
    /// window, creating one if needed). Falls back to the default browser
    /// when no profile directory is given or Chrome is not installed.
    static func open(_ url: URL, inProfileDirectory directory: String?, newWindow: Bool = false) {
        guard let directory, isInstalled else {
            NSWorkspace.shared.open(url)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        var args = ["-na", "Google Chrome", "--args", "--profile-directory=\(directory)"]
        if newWindow { args.append("--new-window") }
        args.append(url.absoluteString)
        process.arguments = args
        try? process.run()
    }

    /// Run a script through `osascript` and return stdout. Off-main safe.
    /// `NSAppleScript` is deliberately avoided: it is main-thread bound and
    /// a slow Chrome would stall the UI for the whole enumeration.
    private static func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
