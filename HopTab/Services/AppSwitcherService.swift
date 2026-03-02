import AppKit
import ApplicationServices

struct WindowInfo: Identifiable {
    let id: Int       // index in the AX window list
    let title: String
    let isMinimized: Bool
}

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

        // 2. Unminimize windows so minimized apps restore on activation
        unminimizeWindows(of: app)

        // 3. Use the older, more aggressive activate API
        //    The macOS 14+ parameterless activate() is weaker and doesn't
        //    always raise windows for apps like Simulator, Terminal, etc.
        app.activate(options: .activateIgnoringOtherApps)

        // 4. Raise the frontmost window via Accessibility API as a fallback.
        //    This forces the window to the top of the window stack, solving
        //    the issue where activate() updates the menu bar but leaves
        //    the window behind other apps.
        raiseFrontWindow(of: app)
    }

    /// Raise only the frontmost window. AX API returns windows front-to-back,
    /// so `windows.first` is the most recently active one.
    private static func raiseFrontWindow(of app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return }

        if let frontWindow = windows.first {
            AXUIElementPerformAction(frontWindow, kAXRaiseAction as CFString)
        }
    }

    /// Minimize the frontmost window of a running app.
    static func minimizeFirstWindow(of app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return }

        if let frontWindow = windows.first {
            AXUIElementSetAttributeValue(frontWindow, kAXMinimizedAttribute as CFString, true as CFBoolean)
        }
    }

    /// Unminimize all minimized windows of a running app.
    private static func unminimizeWindows(of app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return }

        for window in windows {
            var minimized: CFTypeRef?
            let attrResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            if attrResult == .success, let isMin = minimized as? Bool, isMin {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFBoolean)
            }
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

    // MARK: - Window Enumeration

    /// List windows of a running app via AX API, filtering out untitled utility windows.
    static func enumerateWindows(of app: NSRunningApplication) -> [WindowInfo] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return [] }

        var infos: [WindowInfo] = []
        for (index, window) in windows.enumerated() {
            // Get title
            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            let title = (titleValue as? String) ?? ""

            // Skip windows with empty titles (utility panels, etc.)
            guard !title.isEmpty else { continue }

            // Get role — only include standard windows
            var roleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleValue)
            let role = (roleValue as? String) ?? ""
            guard role == (kAXWindowRole as String) else { continue }

            // Get minimized state
            var minValue: CFTypeRef?
            let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minValue)
            let isMinimized = (minResult == .success) && (minValue as? Bool == true)

            infos.append(WindowInfo(id: index, title: title, isMinimized: isMinimized))
        }
        return infos
    }

    /// Raise a specific window by its index in the AX window list.
    /// Re-queries AX at selection time so indices stay fresh.
    static func raiseWindow(of app: NSRunningApplication, atIndex index: Int) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement], index < windows.count else { return }

        let window = windows[index]

        // Unminimize if needed
        var minValue: CFTypeRef?
        let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minValue)
        if minResult == .success, let isMin = minValue as? Bool, isMin {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFBoolean)
        }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}
