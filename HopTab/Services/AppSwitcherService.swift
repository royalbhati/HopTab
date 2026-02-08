import AppKit
import ApplicationServices

enum AppSwitcherService {
    /// Activate (bring to front) the app with the given bundle identifier.
    /// Launches the app if it's not running.
    static func activate(_ app: PinnedApp) {
        if let running = app.runningApplication {
            activateRunning(running)
        } else if let url = app.applicationURL {
            launchApp(at: url)
        }
    }

    private static func activateRunning(_ app: NSRunningApplication) {
        // 1. Unhide first — hidden apps won't come to front otherwise
        if app.isHidden {
            app.unhide()
        }

        // 2. Use the older, more aggressive activate API
        //    The macOS 14+ parameterless activate() is weaker and doesn't
        //    always raise windows for apps like Simulator, Terminal, etc.
        app.activate(options: .activateIgnoringOtherApps)

        // 3. Raise the frontmost window via Accessibility API as a fallback.
        //    This forces the window to the top of the window stack, solving
        //    the issue where activate() updates the menu bar but leaves
        //    the window behind other apps.
        raiseWindows(of: app)
    }

    private static func raiseWindows(of app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return }

        for window in windows {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
    }

    private static func launchApp(at url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, error in
            if let error {
                NSLog("[AppSwitcherService] Failed to launch app: %@", error.localizedDescription)
            }
        }
    }
}
