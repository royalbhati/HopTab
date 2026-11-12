import AppKit
import Carbon.HIToolbox

/// Executes a `CustomCommand` picked in the palette.
enum CustomCommandRunner {
    /// Stamped on every keyboard event HopTab posts, so `HotkeyService`'s
    /// tap lets it through instead of treating it as a user shortcut.
    static let syntheticUserData: Int64 = 0x484F_5054 // "HOPT"

    @MainActor
    static func run(_ command: CustomCommand, frontmostBefore: NSRunningApplication?) {
        switch command.action {
        case .openURL(let string):
            guard let url = urlFrom(string) else { return }
            open([url], with: command.appBundleIdentifier)
        case .openPath(let path):
            let expanded = (path as NSString).expandingTildeInPath
            open([URL(fileURLWithPath: expanded)], with: command.appBundleIdentifier)
        case .sendShortcut(let shortcut):
            guard let bundleId = command.appBundleIdentifier else { return }
            activate(bundleId: bundleId) {
                post(shortcut)
            }
        case .runShell(let script):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                NSLog("[HopTab] Shell command failed to start: %@", error.localizedDescription)
            }
        case .pasteText(let text):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let paste = CustomShortcut(modifierFlagsRawValue: CGEventFlags.maskCommand.rawValue, keyCode: Int64(kVK_ANSI_V))
            if let bundleId = command.appBundleIdentifier {
                activate(bundleId: bundleId) { post(paste) }
            } else if let front = frontmostBefore {
                front.activate(options: .activateIgnoringOtherApps)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { post(paste) }
            }
        }
    }

    // MARK: - Helpers

    private static func urlFrom(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil { return url }
        return URL(string: "https://" + trimmed)
    }

    private static func open(_ urls: [URL], with bundleId: String?) {
        if let bundleId, let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config)
        } else {
            for url in urls { NSWorkspace.shared.open(url) }
        }
    }

    /// Bring the app to the front, launching it if needed, then run `then`
    /// once it is frontmost (or after a bounded wait).
    @MainActor
    private static func activate(bundleId: String, then: @escaping @MainActor () -> Void) {
        if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
            app.activate(options: .activateIgnoringOtherApps)
            waitUntilFront(app, attempts: 10, then: then)
            return
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
            guard let app else { return }
            DispatchQueue.main.async {
                // A freshly launched app needs a moment before it takes keys.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    waitUntilFront(app, attempts: 10, then: then)
                }
            }
        }
    }

    @MainActor
    private static func waitUntilFront(_ app: NSRunningApplication, attempts: Int, then: @escaping @MainActor () -> Void) {
        if app.isActive || attempts == 0 {
            // One more beat so the key window has settled after activation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { then() }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            waitUntilFront(app, attempts: attempts - 1, then: then)
        }
    }

    /// Post a key chord as if typed. Tagged so HopTab's own tap ignores it.
    static func post(_ shortcut: CustomShortcut) {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return }
        source.userData = syntheticUserData
        let key = CGKeyCode(truncatingIfNeeded: shortcut.keyCode)
        var flags = shortcut.modifierFlags
        if shortcut.requiresFunctionModifier { flags.insert(.maskSecondaryFn) }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else { return }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
