import AppKit
import ApplicationServices

enum SessionSnapshotService {

    /// CGWindowIDs captured alongside each snapshot, parallel to `snapshot.windows`.
    /// Kept in memory only — CGWindowIDs are stable within a login session, which is
    /// exactly the window ("Save & Close" → "Restore" without relaunch) where they help.
    /// Old persisted snapshots decode unchanged; restores without IDs fall back to
    /// title/frame matching.
    private static var capturedWindowIDs: [UUID: [CGWindowID?]] = [:]

    // MARK: - Capture

    /// Snapshot window positions for all running pinned apps in a profile.
    static func captureSnapshot(for profile: Profile) -> SessionSnapshot {
        var windows: [WindowSnapshot] = []
        var windowIDs: [CGWindowID?] = []
        var zIndex = 0

        for app in profile.pinnedApps {
            guard let running = app.runningApplication else { continue }
            let axApp = AXUIElementCreateApplication(running.processIdentifier)

            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
            guard result == .success, let axWindows = value as? [AXUIElement] else { continue }

            for axWindow in axWindows {
                // Only capture standard windows
                var roleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXRoleAttribute as CFString, &roleRef)
                let role = (roleRef as? String) ?? ""
                guard role == (kAXWindowRole as String) else { continue }

                // Title
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""

                // Position
                var posRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
                var position = CGPoint.zero
                if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &position) }

                // Size
                var sizeRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
                var size = CGSize.zero
                if let sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) }

                // Minimized
                var minRef: CFTypeRef?
                let minResult = AXUIElementCopyAttributeValue(axWindow, kAXMinimizedAttribute as CFString, &minRef)
                let isMinimized = (minResult == .success) && (minRef as? Bool == true)

                windows.append(WindowSnapshot(
                    bundleIdentifier: app.bundleIdentifier,
                    windowTitle: title,
                    frame: CGRect(origin: position, size: size),
                    isMinimized: isMinimized,
                    zIndex: zIndex
                ))
                // Stable window ID for restore matching (dynamic titles break exact-title match)
                var windowID: CGWindowID = 0
                if _AXUIElementGetWindow(axWindow, &windowID) == .success, windowID != 0 {
                    windowIDs.append(windowID)
                } else {
                    windowIDs.append(nil)
                }
                zIndex += 1
            }
        }

        capturedWindowIDs[profile.id] = windowIDs
        return SessionSnapshot(
            profileId: profile.id,
            capturedAt: Date(),
            windows: windows,
            displayConfigKey: SessionSnapshot.currentDisplayConfigKey
        )
    }

    // MARK: - Restore

    /// Restore saved window positions for all running pinned apps in a profile.
    static func restoreSnapshot(_ snapshot: SessionSnapshot, for profile: Profile) {
        for app in profile.pinnedApps {
            restoreWindows(from: snapshot, bundleIdentifier: app.bundleIdentifier)
        }
        raiseWindows(in: snapshot)
    }

    /// Final cleanup after a readiness-driven restore: restore frames only for apps
    /// that were never individually restored (so user adjustments made mid-restore
    /// aren't reverted), then re-assert the saved z-order.
    static func finalizeRestore(_ snapshot: SessionSnapshot, for profile: Profile, skipping restored: Set<String>) {
        for app in profile.pinnedApps where !restored.contains(app.bundleIdentifier) {
            restoreWindows(from: snapshot, bundleIdentifier: app.bundleIdentifier)
        }
        raiseWindows(in: snapshot)
    }

    /// Whether a running app exposes at least one AX window (i.e. is ready to be positioned).
    static func appHasWindows(_ running: NSRunningApplication) -> Bool {
        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let axWindows = value as? [AXUIElement]
        else { return false }
        return !axWindows.isEmpty
    }

    /// Restore saved frames for a single app's windows.
    /// Matching order: CGWindowID (same login session) → exact title →
    /// frame proximity in saved-index order.
    static func restoreWindows(from snapshot: SessionSnapshot, bundleIdentifier: String) {
        let capturedIDs = capturedWindowIDs[snapshot.profileId] ?? []
        var saved: [(ws: WindowSnapshot, windowID: CGWindowID?)] = []
        for (index, ws) in snapshot.windows.enumerated() where ws.bundleIdentifier == bundleIdentifier {
            saved.append((ws: ws, windowID: index < capturedIDs.count ? capturedIDs[index] : nil))
        }
        guard !saved.isEmpty,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        else { return }

        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let axWindows = value as? [AXUIElement] else { return }

        // Enumerate live windows once, with their identity/title/frame
        var live: [(element: AXUIElement, windowID: CGWindowID?, title: String, frame: CGRect)] = []
        for axWindow in axWindows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            let title = (titleRef as? String) ?? ""

            var windowID: CGWindowID = 0
            let hasID = _AXUIElementGetWindow(axWindow, &windowID) == .success && windowID != 0

            var posRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXPositionAttribute as CFString, &posRef)
            var position = CGPoint.zero
            if let posRef { AXValueGetValue(posRef as! AXValue, .cgPoint, &position) }

            var sizeRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXSizeAttribute as CFString, &sizeRef)
            var size = CGSize.zero
            if let sizeRef { AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) }

            live.append((element: axWindow, windowID: hasID ? windowID : nil, title: title, frame: CGRect(origin: position, size: size)))
        }
        guard !live.isEmpty else { return }

        var claimed = [Bool](repeating: false, count: live.count)
        var matchedLiveIndex = [Int?](repeating: nil, count: saved.count)

        // Pass 1: stable CGWindowID
        for (si, s) in saved.enumerated() {
            guard let wid = s.windowID,
                  let li = live.indices.first(where: { !claimed[$0] && live[$0].windowID == wid })
            else { continue }
            matchedLiveIndex[si] = li
            claimed[li] = true
        }
        // Pass 2: exact title
        for (si, s) in saved.enumerated() where matchedLiveIndex[si] == nil {
            guard let li = live.indices.first(where: { !claimed[$0] && live[$0].title == s.ws.windowTitle })
            else { continue }
            matchedLiveIndex[si] = li
            claimed[li] = true
        }
        // Pass 3: frame proximity, in saved-index order
        for si in saved.indices where matchedLiveIndex[si] == nil {
            let target = saved[si].ws.frame
            let li = live.indices
                .filter { !claimed[$0] }
                .min { frameDistance(live[$0].frame, target) < frameDistance(live[$1].frame, target) }
            guard let li else { break }
            matchedLiveIndex[si] = li
            claimed[li] = true
        }

        for (si, s) in saved.enumerated() {
            guard let li = matchedLiveIndex[si] else { continue }
            let axWindow = live[li].element

            // Set position
            var position = s.ws.frame.origin
            if let posValue = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(axWindow, kAXPositionAttribute as CFString, posValue)
            }

            // Set size
            var size = s.ws.frame.size
            if let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(axWindow, kAXSizeAttribute as CFString, sizeValue)
            }

            // Restore minimized state
            AXUIElementSetAttributeValue(
                axWindow,
                kAXMinimizedAttribute as CFString,
                s.ws.isMinimized as CFBoolean
            )
        }
    }

    private static func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.origin.x - b.origin.x) + abs(a.origin.y - b.origin.y)
            + abs(a.width - b.width) + abs(a.height - b.height)
    }

    /// Restore z-ordering: raise windows from back to front.
    private static func raiseWindows(in snapshot: SessionSnapshot) {
        let capturedIDs = capturedWindowIDs[snapshot.profileId] ?? []
        let sortedWindows = snapshot.windows.enumerated().sorted { $0.element.zIndex > $1.element.zIndex }
        for (index, ws) in sortedWindows {
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: ws.bundleIdentifier).first else { continue }
            let axApp = AXUIElementCreateApplication(running.processIdentifier)
            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value)
            guard result == .success, let axWindows = value as? [AXUIElement] else { continue }

            let savedID = index < capturedIDs.count ? capturedIDs[index] : nil
            let byID = savedID.flatMap { wid in
                axWindows.first { axWindow in
                    var windowID: CGWindowID = 0
                    return _AXUIElementGetWindow(axWindow, &windowID) == .success && windowID == wid
                }
            }
            let match = byID ?? axWindows.first { axWindow in
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                return (titleRef as? String) == ws.windowTitle
            }
            if let match {
                AXUIElementPerformAction(match, kAXRaiseAction as CFString)
            }
        }
    }

    // MARK: - Hide / Unhide

    /// Hide outgoing profile's apps, skipping any shared with the incoming profile.
    static func hideProfileApps(_ outgoing: Profile, excluding incoming: Profile) {
        let incomingBundles = Set(incoming.pinnedApps.map(\.bundleIdentifier))
        for app in outgoing.pinnedApps {
            guard !incomingBundles.contains(app.bundleIdentifier) else { continue }
            app.runningApplication?.hide()
        }
    }

    /// Unhide all running apps belonging to a profile.
    static func unhideProfileApps(_ profile: Profile) {
        for app in profile.pinnedApps {
            guard let running = app.runningApplication, running.isHidden else { continue }
            running.unhide()
        }
    }

    // MARK: - Save & Close / Restore

    /// Quit all running apps in a profile (used for "Save & Close").
    /// Returns bundle IDs whose terminate() request was refused outright —
    /// callers should still re-check later for apps stalled on unsaved-changes dialogs.
    @discardableResult
    static func quitProfileApps(_ profile: Profile) -> [String] {
        var refused: [String] = []
        for app in profile.pinnedApps {
            guard let running = app.runningApplication else { continue }
            if !running.terminate() {
                refused.append(app.bundleIdentifier)
            }
        }
        return refused
    }

    /// Launch all pinned apps in a profile that aren't already running.
    static func launchProfileApps(_ profile: Profile) {
        launchApps(profile.pinnedApps)
    }

    /// Launch a subset of pinned apps (skips apps already running).
    /// Used by launch orchestration to launch one priority group at a time.
    static func launchApps(_ apps: [PinnedApp]) {
        for app in apps {
            guard app.runningApplication == nil, let url = app.applicationURL else { continue }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }
        }
    }

    /// Open a list of URLs / file paths in a specific app (launch orchestration's
    /// `openURLs`). Invalid or unresolvable entries are logged and skipped —
    /// this never blocks or fails a restore.
    static func openURLs(_ strings: [String], inApp bundleIdentifier: String) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            NSLog("[SessionSnapshot] openURLs: no application found for %@ — skipping %d URL(s)", bundleIdentifier, strings.count)
            return
        }

        var urls: [URL] = []
        for raw in strings {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
                // File path — expand tilde and require it to exist
                let expanded = NSString(string: trimmed).expandingTildeInPath
                if FileManager.default.fileExists(atPath: expanded) {
                    urls.append(URL(fileURLWithPath: expanded))
                } else {
                    NSLog("[SessionSnapshot] openURLs: path does not exist, skipping: %@", trimmed)
                }
            } else if let url = URL(string: trimmed), url.scheme != nil {
                urls.append(url)
            } else if let url = URL(string: "https://\(trimmed)"), trimmed.contains(".") {
                // Bare domain like "github.com/foo" — assume https
                urls.append(url)
            } else {
                NSLog("[SessionSnapshot] openURLs: invalid entry, skipping: %@", trimmed)
            }
        }
        guard !urls.isEmpty else { return }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        NSWorkspace.shared.open(urls, withApplicationAt: appURL, configuration: config) { _, error in
            if let error {
                NSLog("[SessionSnapshot] openURLs: failed for %@: %@", bundleIdentifier, error.localizedDescription)
            }
        }
    }

    /// Check if any pinned apps in a profile are currently running.
    static func hasRunningApps(_ profile: Profile) -> Bool {
        profile.pinnedApps.contains { $0.isRunning }
    }
}

/// Extracts the CGWindowID from an AXUIElement window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError
