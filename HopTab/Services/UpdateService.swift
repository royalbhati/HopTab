import Foundation
import AppKit

/// Lightweight auto-update checker.
/// Point `feedURL` at a JSON endpoint with this format:
/// ```json
/// {
///   "version": "0.4.0",
///   "build": 4,
///   "downloadURL": "https://example.com/HopTab-0.4.0.dmg",
///   "releaseNotes": "New layout templates, bug fixes."
/// }
/// ```
@MainActor
final class UpdateService: ObservableObject {
    static let shared = UpdateService()

    /// The URL to check for updates. Set this to your hosted JSON endpoint.
    /// e.g. a GitHub Pages URL, raw GitHub gist, or any static host.
    private static let defaultFeedURL = "https://www.royalbhati.com/hoptab/update.json"
    private static let feedURLKey = "updateFeedURL"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let checkInterval: TimeInterval = 4 * 3600 // every 4 hours

    @Published private(set) var availableUpdate: UpdateInfo?
    @Published private(set) var isChecking = false
    @Published var autoCheckEnabled: Bool = UserDefaults.standard.object(forKey: "autoCheckUpdates") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "autoCheckUpdates") {
        didSet { UserDefaults.standard.set(autoCheckEnabled, forKey: "autoCheckUpdates") }
    }

    struct UpdateInfo: Codable {
        let version: String
        let build: Int?
        let downloadURL: String
        let releaseNotes: String?
    }

    var feedURL: String {
        get { UserDefaults.standard.string(forKey: Self.feedURLKey) ?? Self.defaultFeedURL }
        set { UserDefaults.standard.set(newValue, forKey: Self.feedURLKey) }
    }

    private var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    private var currentBuild: Int {
        let str = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
        return Int(str) ?? 0
    }

    // MARK: - Check on Launch

    func checkOnLaunchIfNeeded() {
        guard autoCheckEnabled else { return }
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        let now = Date().timeIntervalSince1970
        guard now - last > Self.checkInterval else { return }
        Task { await checkForUpdates(silent: true) }
    }

    // MARK: - Manual Check

    func checkForUpdates(silent: Bool = false) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)

        guard let url = URL(string: feedURL) else {
            if !silent { showAlert(title: "Update Error", message: "Invalid update feed URL.") }
            return
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let info = try JSONDecoder().decode(UpdateInfo.self, from: data)

            if isNewer(remote: info) {
                availableUpdate = info
                showUpdateAvailable(info)
            } else if !silent {
                showAlert(title: "No Updates", message: "You're running the latest version (\(currentVersion)).")
            }
        } catch {
            if !silent {
                showAlert(title: "Update Check Failed", message: "Could not reach the update server.\n\(error.localizedDescription)")
            }
        }
    }

    // MARK: - Download

    func downloadUpdate(_ info: UpdateInfo) {
        guard let url = URL(string: info.downloadURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Version Comparison

    private func isNewer(remote: UpdateInfo) -> Bool {
        // Compare build number first if available
        if let remoteBuild = remote.build, remoteBuild > currentBuild {
            return true
        }
        // Fall back to semantic version comparison
        return compareVersions(remote.version, isGreaterThan: currentVersion)
    }

    private func compareVersions(_ a: String, isGreaterThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av > bv { return true }
            if av < bv { return false }
        }
        return false
    }

    // MARK: - UI

    private func showUpdateAvailable(_ info: UpdateInfo) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "HopTab \(info.version) is available (you have \(currentVersion))."
        if let notes = info.releaseNotes, !notes.isEmpty {
            alert.informativeText += "\n\n\(notes)"
        }
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Download")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            downloadUpdate(info)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
