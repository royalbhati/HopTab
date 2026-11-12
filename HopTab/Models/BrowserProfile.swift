import Foundation

/// A browser profile a workspace can be tied to. Switching to the workspace
/// brings that profile's window to the front (opening one if needed).
enum BrowserProfile: Codable, Equatable, Hashable {
    /// Google Chrome profile: on-disk directory (`Default`, `Profile 2`) and
    /// the name Chrome shows for it.
    case chrome(directory: String, name: String)
    /// Safari profile, known only by the name Safari shows in its File menu
    /// ("New Work Window") and on each window's toolbar.
    case safari(name: String)

    var browserName: String {
        switch self {
        case .chrome: return "Chrome"
        case .safari: return "Safari"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .chrome: return ChromeDataService.bundleIdentifier
        case .safari: return SafariProfilesService.bundleIdentifier
        }
    }

    var profileName: String {
        switch self {
        case .chrome(_, let name): return name
        case .safari(let name): return name
        }
    }

    var displayName: String { "\(browserName) \u{00B7} \(profileName)" }

    /// Stable key for pickers.
    var key: String {
        switch self {
        case .chrome(let directory, _): return "chrome:\(directory)"
        case .safari(let name): return "safari:\(name)"
        }
    }

    /// Raise this profile's window, opening one when the browser has none.
    func activate() {
        switch self {
        case .chrome(let directory, let name):
            ChromeDataService.switchToProfile(directory: directory, name: name)
        case .safari(let name):
            SafariProfilesService.switchToProfile(name: name)
        }
    }
}
