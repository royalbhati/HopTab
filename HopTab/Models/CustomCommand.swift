import AppKit
import Combine

/// A row the user adds to the ⌥K palette themselves: a link, a file, a
/// keystroke sent to an app, a shell command, or a snippet to paste.
///
/// Commands can be scoped to an app. A scoped command is still listed from
/// anywhere, but ranks higher when that app is in front, and for the
/// keystroke and paste actions the app is also where the keys go.
struct CustomCommand: Codable, Identifiable, Equatable {
    enum Action: Codable, Equatable {
        /// Open a URL, with the scoped app when one is set, else the default handler.
        case openURL(String)
        /// Open a file or folder, with the scoped app when one is set.
        case openPath(String)
        /// Activate the scoped app and press this chord in it.
        case sendShortcut(CustomShortcut)
        /// Run in a login shell. Output is discarded; failures are logged.
        case runShell(String)
        /// Put the text on the pasteboard and press ⌘V in the scoped app
        /// (or whichever app was in front).
        case pasteText(String)

        var kindName: String {
            switch self {
            case .openURL: return "Open link"
            case .openPath: return "Open file or folder"
            case .sendShortcut: return "Press shortcut"
            case .runShell: return "Run shell command"
            case .pasteText: return "Paste text"
            }
        }

        var systemImage: String {
            switch self {
            case .openURL: return "link"
            case .openPath: return "folder"
            case .sendShortcut: return "keyboard"
            case .runShell: return "terminal"
            case .pasteText: return "doc.on.clipboard"
            }
        }

        /// What the palette shows under the title.
        var summary: String {
            switch self {
            case .openURL(let s): return s
            case .openPath(let s): return (s as NSString).abbreviatingWithTildeInPath
            case .sendShortcut(let k): return k.displayName
            case .runShell(let s): return s
            case .pasteText(let s): return s.replacingOccurrences(of: "\n", with: " ")
            }
        }
    }

    var id: UUID
    var title: String
    /// Extra words the fuzzy matcher may hit, comma or space separated.
    var keywords: String
    /// Bundle identifier of the app this command belongs to, if any.
    var appBundleIdentifier: String?
    var action: Action

    init(id: UUID = UUID(), title: String, keywords: String = "", appBundleIdentifier: String? = nil, action: Action) {
        self.id = id
        self.title = title
        self.keywords = keywords
        self.appBundleIdentifier = appBundleIdentifier
        self.action = action
    }

    var keywordList: [String] {
        keywords.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init).filter { !$0.isEmpty }
    }

    /// Display name of the scoped app, looked up from the installed copy.
    var appDisplayName: String? {
        guard let bundleId = appBundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var appIcon: NSImage? {
        guard let bundleId = appBundleIdentifier,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        return InstalledAppsService.icon(forPath: url.path)
    }

    /// Keystroke and paste need somewhere to send keys.
    var needsApp: Bool {
        if case .sendShortcut = action { return true }
        return false
    }
}

/// Persists the user's commands in UserDefaults and hands them to the
/// palette index on every open.
@MainActor
final class CustomCommandsStore: ObservableObject {
    static let defaultsKey = "customCommands"

    @Published private(set) var commands: [CustomCommand] = []

    init() { load() }

    func add(_ command: CustomCommand) {
        commands.append(command)
        save()
    }

    func update(_ command: CustomCommand) {
        guard let i = commands.firstIndex(where: { $0.id == command.id }) else { return add(command) }
        commands[i] = command
        save()
    }

    func remove(id: UUID) {
        commands.removeAll { $0.id == id }
        save()
    }

    func command(id: UUID) -> CustomCommand? {
        commands.first { $0.id == id }
    }

    // MARK: Import / export

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(commands)
    }

    /// Merges by id: an imported command with a known id replaces it, new
    /// ids are appended. Returns how many were added or replaced.
    @discardableResult
    func importData(_ data: Data) throws -> Int {
        let imported = try JSONDecoder().decode([CustomCommand].self, from: data)
        for command in imported {
            if let i = commands.firstIndex(where: { $0.id == command.id }) {
                commands[i] = command
            } else {
                commands.append(command)
            }
        }
        save()
        return imported.count
    }

    // MARK: Persistence

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
        do {
            commands = try JSONDecoder().decode([CustomCommand].self, from: data)
        } catch {
            NSLog("[HopTab] Could not decode custom commands: %@", error.localizedDescription)
        }
    }

    private func save() {
        do {
            UserDefaults.standard.set(try JSONEncoder().encode(commands), forKey: Self.defaultsKey)
        } catch {
            NSLog("[HopTab] Could not save custom commands: %@", error.localizedDescription)
        }
    }
}
