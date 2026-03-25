import AppKit
import ApplicationServices

struct WindowInfo: Identifiable {
    let id: CGWindowID   // stable CGWindowID (kCGWindowNumber)
    let title: String
    let isMinimized: Bool
    let spaceID: Int?    // nil for minimized windows (they live in the Dock, not on a Space)
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

    /// Query CGWindowList for all windows of a given PID.
    /// Returns a lookup of [CGWindowID: spaceID] for cross-referencing with AX windows.
    private static func cgWindowSpaces(for pid: pid_t) -> [CGWindowID: Int] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }

        var result: [CGWindowID: Int] = [:]
        for info in infoList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == pid,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let spaceID = info["kCGWindowWorkspace" as String] as? Int
            else { continue }
            result[windowID] = spaceID
        }
        return result
    }

    /// List windows of a running app via AX API, enriched with stable CGWindowID and Space info.
    static func enumerateWindows(of app: NSRunningApplication) -> [WindowInfo] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return [] }

        let spaceMap = cgWindowSpaces(for: app.processIdentifier)

        var infos: [WindowInfo] = []
        for window in windows {
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

            // Bridge AX window → stable CGWindowID
            var windowID: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &windowID) == .success, windowID != 0 else { continue }

            let spaceID = isMinimized ? nil : spaceMap[windowID]

            infos.append(WindowInfo(id: windowID, title: title, isMinimized: isMinimized, spaceID: spaceID))
        }
        return infos
    }

    /// Filter windows to only those on the current Space.
    /// Minimized windows and windows with unknown Space are included (fail-open).
    static func windowsOnCurrentSpace(_ windows: [WindowInfo]) -> [WindowInfo] {
        guard let currentSpace = SpaceService.currentSpaceId else {
            return windows
        }
        return windows.filter { window in
            window.isMinimized || window.spaceID == nil || window.spaceID == currentSpace
        }
    }

    /// Raise a specific window by its stable CGWindowID.
    /// Re-queries AX at selection time to find the matching element.
    static func raiseWindow(of app: NSRunningApplication, windowID: CGWindowID) {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else { return }

        for window in windows {
            var wid: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &wid) == .success, wid == windowID else { continue }

            // Unminimize if needed
            var minValue: CFTypeRef?
            let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minValue)
            if minResult == .success, let isMin = minValue as? Bool, isMin {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFBoolean)
            }

            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return
        }
    }
}

// MARK: - Private AX bridge

/// Extracts the CGWindowID from an AXUIElement window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError
