import AppKit
import ApplicationServices

enum SnapDirection: String, CaseIterable, Codable {
    // Halves
    case left, right, topHalf, bottomHalf
    // Quarters
    case topLeft, topRight, bottomLeft, bottomRight
    // Thirds
    case firstThird, centerThird, lastThird
    case firstTwoThirds, lastTwoThirds
    // Full / center
    case full, center
    // Monitor movement
    case nextMonitor, previousMonitor
    // Undo
    case undo

    var displayName: String {
        switch self {
        case .left: return "Left Half"
        case .right: return "Right Half"
        case .topHalf: return "Top Half"
        case .bottomHalf: return "Bottom Half"
        case .topLeft: return "Top Left"
        case .topRight: return "Top Right"
        case .bottomLeft: return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        case .firstThird: return "First Third"
        case .centerThird: return "Center Third"
        case .lastThird: return "Last Third"
        case .firstTwoThirds: return "First Two Thirds"
        case .lastTwoThirds: return "Last Two Thirds"
        case .full: return "Maximize"
        case .center: return "Center"
        case .nextMonitor: return "Next Monitor"
        case .previousMonitor: return "Previous Monitor"
        case .undo: return "Undo Snap"
        }
    }

    /// Directions that produce a snap frame (excludes meta-actions).
    static var snappableDirections: [SnapDirection] {
        allCases.filter { $0 != .nextMonitor && $0 != .previousMonitor && $0 != .undo }
    }

    /// Fractional rect (x, y, w, h) relative to screen visible frame.
    var fractions: (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        switch self {
        case .left:           return (0,     0,     0.5,   1)
        case .right:          return (0.5,   0,     0.5,   1)
        case .topHalf:        return (0,     0,     1,     0.5)
        case .bottomHalf:     return (0,     0.5,   1,     0.5)
        case .topLeft:        return (0,     0,     0.5,   0.5)
        case .topRight:       return (0.5,   0,     0.5,   0.5)
        case .bottomLeft:     return (0,     0.5,   0.5,   0.5)
        case .bottomRight:    return (0.5,   0.5,   0.5,   0.5)
        case .firstThird:     return (0,     0,     1/3,   1)
        case .centerThird:    return (1/3,   0,     1/3,   1)
        case .lastThird:      return (2/3,   0,     1/3,   1)
        case .firstTwoThirds: return (0,     0,     2/3,   1)
        case .lastTwoThirds:  return (1/3,   0,     2/3,   1)
        case .full:           return (0,     0,     1,     1)
        case .center:         return (1/6,   1/6,   2/3,   2/3)
        // Meta-actions — no frame
        case .nextMonitor, .previousMonitor, .undo:
            return (0, 0, 1, 1)
        }
    }
}

enum LayoutService {

    // MARK: - Configuration

    /// Gap (in points) between snapped windows and screen edges.
    /// Stored in UserDefaults so the user can tweak it.
    static var gapSize: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "windowGap")
        return saved > 0 ? saved : 0
    }

    /// Maximum number of retries when a window doesn't reach the target frame.
    private static let maxRetries = 4

    /// Tolerance in points — if actual position is within this of target, accept it.
    private static let tolerance: CGFloat = 5

    // MARK: - Undo Storage

    /// Stores the previous frame before each snap, keyed by "pid-windowTitle".
    private static var previousFrames: [String: CGRect] = [:]

    private static func undoKey(pid: pid_t, window: AXUIElement) -> String {
        var titleRef: CFTypeRef?
        let title: String
        if AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef) == .success,
           let t = titleRef as? String {
            title = t
        } else {
            title = "untitled"
        }
        return "\(pid)-\(title)"
    }

    private static func saveFrameForUndo(_ window: AXUIElement, pid: pid_t) {
        let frame = getWindowFrame(window)
        guard !frame.isEmpty else { return }
        let key = undoKey(pid: pid, window: window)
        previousFrames[key] = frame
    }

    /// Restore the frontmost window to its position before the last snap.
    static func undoSnap() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        guard let axWindow = focusedOrBestWindow(of: axApp) else { return }

        let key = undoKey(pid: frontApp.processIdentifier, window: axWindow)
        guard let savedFrame = previousFrames[key] else { return }
        moveWindow(axWindow, to: savedFrame)
        previousFrames.removeValue(forKey: key)
    }

    // MARK: - Cycle Through Sizes

    private static var lastSnap: (pid: pid_t, direction: SnapDirection, cycleIndex: Int, timestamp: Date)?

    /// Cycle sequences: pressing the same direction repeatedly cycles through these sizes.
    private static let cycleSequences: [SnapDirection: [SnapDirection]] = [
        .left:  [.left, .firstThird, .firstTwoThirds],
        .right: [.right, .lastThird, .lastTwoThirds],
        .topHalf: [.topHalf],
        .bottomHalf: [.bottomHalf],
        .full: [.full],
        .center: [.center],
    ]

    /// Resolve the actual snap direction, advancing the cycle if the same key is repeated.
    private static func resolvedDirection(for direction: SnapDirection, pid: pid_t) -> SnapDirection {
        let now = Date()
        let sequence = cycleSequences[direction] ?? [direction]
        guard sequence.count > 1 else { return direction }

        if let last = lastSnap,
           last.pid == pid,
           last.direction == direction,
           now.timeIntervalSince(last.timestamp) < 1.5 {
            let nextIndex = (last.cycleIndex + 1) % sequence.count
            lastSnap = (pid: pid, direction: direction, cycleIndex: nextIndex, timestamp: now)
            return sequence[nextIndex]
        }

        lastSnap = (pid: pid, direction: direction, cycleIndex: 0, timestamp: now)
        return sequence[0]
    }

    // MARK: - Apply Full Layout

    /// Apply a layout template to the active profile's pinned apps.
    /// Each zone is mapped to a bundle identifier via the binding.
    /// Returns the number of windows successfully moved, or -1 if AX is not trusted.
    @discardableResult
    static func applyLayout(
        binding: LayoutBinding,
        template: LayoutTemplate,
        profile: Profile,
        screen: CGRect? = nil
    ) -> Int {
        guard AXIsProcessTrusted() else { return -1 }

        let screenFrame = screen ?? bestScreen()
        guard !screenFrame.isEmpty else { return 0 }

        var appWindows: [(zone: LayoutZone, app: AXUIElement, window: AXUIElement)] = []

        for zone in template.zones {
            guard let bundleId = binding.zoneAssignments[zone.id] else { continue }
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { continue }

            if running.isHidden { running.unhide() }
            running.activate()

            let axApp = AXUIElementCreateApplication(running.processIdentifier)

            // Enable enhanced AX BEFORE trying to find windows —
            // Chrome, Zed, Electron apps won't expose their window list without this.
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, true as CFBoolean)
        }

        // Brief pause to let apps activate and expose their AX trees.
        // Without this, apps like Chrome/Zed/Wezterm silently return no windows.
        usleep(150_000) // 150ms

        for zone in template.zones {
            guard let bundleId = binding.zoneAssignments[zone.id] else { continue }
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { continue }

            let axApp = AXUIElementCreateApplication(running.processIdentifier)

            // Retry window lookup — stubborn apps sometimes need a second attempt
            var window = bestWindow(of: axApp)
            if window == nil {
                usleep(100_000) // 100ms extra
                window = bestWindow(of: axApp)
            }
            guard let window else { continue }
            appWindows.append((zone: zone, app: axApp, window: window))
        }

        var movedCount = 0
        for entry in appWindows {
            prepareWindow(entry.window, app: entry.app)

            let targetFrame = entry.zone.frame(in: screenFrame)
            let gappedFrame = applyGaps(to: targetFrame, in: screenFrame, zone: entry.zone)
            moveWindow(entry.window, to: gappedFrame)
            movedCount += 1
        }

        // Raise windows in zone order (last = frontmost)
        for entry in appWindows {
            AXUIElementPerformAction(entry.window, kAXRaiseAction as CFString)
        }

        return movedCount
    }

    // MARK: - Quick Snap (frontmost window)

    /// Snap the frontmost window of the frontmost app to a predefined region.
    static func snapFrontmost(to direction: SnapDirection) {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }

        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        guard let axWindow = focusedOrBestWindow(of: axApp) else { return }

        let screenFrame = screenForWindow(axWindow) ?? bestScreen()
        guard !screenFrame.isEmpty else { return }

        // Save for undo before snapping
        saveFrameForUndo(axWindow, pid: frontApp.processIdentifier)

        // Resolve cycling
        let resolved = resolvedDirection(for: direction, pid: frontApp.processIdentifier)

        prepareWindow(axWindow, app: axApp)
        let targetFrame = snapFrame(for: resolved, in: screenFrame)
        moveWindow(axWindow, to: targetFrame)
    }

    /// Snap a specific app (by bundle ID) to a direction.
    static func snapApp(bundleIdentifier: String, to direction: SnapDirection) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }

        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        guard let axWindow = focusedOrBestWindow(of: axApp) else { return }

        let screenFrame = screenForWindow(axWindow) ?? bestScreen()
        guard !screenFrame.isEmpty else { return }

        // Save for undo before snapping
        saveFrameForUndo(axWindow, pid: running.processIdentifier)

        // Resolve cycling
        let resolved = resolvedDirection(for: direction, pid: running.processIdentifier)

        prepareWindow(axWindow, app: axApp)
        let targetFrame = snapFrame(for: resolved, in: screenFrame)
        moveWindow(axWindow, to: targetFrame)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        running.activate()
    }

    // MARK: - Move Between Monitors

    /// Move the frontmost window to the next monitor (left-to-right order, wrapping).
    static func moveFrontmostToNextMonitor() {
        moveFrontmostToMonitor(offset: 1)
    }

    /// Move the frontmost window to the previous monitor (left-to-right order, wrapping).
    static func moveFrontmostToPreviousMonitor() {
        moveFrontmostToMonitor(offset: -1)
    }

    private static func moveFrontmostToMonitor(offset: Int) {
        let screens = NSScreen.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
        guard screens.count > 1 else { return }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
        guard let axWindow = focusedOrBestWindow(of: axApp) else { return }

        let windowFrame = getWindowFrame(axWindow)
        guard !windowFrame.isEmpty else { return }

        // Find which screen the window is currently on
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = primaryHeight - windowFrame.origin.y
        let cocoaPoint = NSPoint(x: windowFrame.midX, y: cocoaY)

        guard let currentScreenIndex = screens.firstIndex(where: { NSMouseInRect(cocoaPoint, $0.frame, false) }) else { return }

        // Calculate target screen
        let targetIndex = ((currentScreenIndex + offset) % screens.count + screens.count) % screens.count
        let targetScreen = screens[targetIndex]
        let currentScreen = screens[currentScreenIndex]

        let currentVisible = quartzVisibleFrame(for: currentScreen)
        let targetVisible = quartzVisibleFrame(for: targetScreen)

        // Proportional placement: preserve relative position
        let relX = (windowFrame.origin.x - currentVisible.origin.x) / currentVisible.width
        let relY = (windowFrame.origin.y - currentVisible.origin.y) / currentVisible.height
        let relW = windowFrame.width / currentVisible.width
        let relH = windowFrame.height / currentVisible.height

        let newFrame = CGRect(
            x: targetVisible.origin.x + relX * targetVisible.width,
            y: targetVisible.origin.y + relY * targetVisible.height,
            width: relW * targetVisible.width,
            height: relH * targetVisible.height
        )

        saveFrameForUndo(axWindow, pid: frontApp.processIdentifier)
        prepareWindow(axWindow, app: axApp)
        moveWindow(axWindow, to: newFrame)
    }

    // MARK: - Window Preparation

    /// Prepare a window for snapping: enable enhanced AX, unminimize, exit fullscreen.
    private static func prepareWindow(_ window: AXUIElement, app: AXUIElement) {
        // Enable enhanced user interface — makes Electron, Chrome, etc. respond to AX properly
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, true as CFBoolean)

        // Unminimize
        var minRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success,
           (minRef as? Bool) == true {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFBoolean)
            usleep(200_000) // 200ms for unminimize animation
        }

        // Exit native macOS fullscreen if active
        var fullscreenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fullscreenRef) == .success,
           (fullscreenRef as? Bool) == true {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, false as CFBoolean)
            usleep(700_000) // 700ms for fullscreen exit animation
        }
    }

    // MARK: - Window Finding

    /// Get the focused window, falling back to the best standard window.
    private static func focusedOrBestWindow(of app: AXUIElement) -> AXUIElement? {
        // Try the focused window first — this is what the user is looking at
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef,
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let win = focused as! AXUIElement
            if isStandardWindow(win) { return win }
        }
        return bestWindow(of: app)
    }

    /// Find the best standard window of an app (skips dialogs, sheets, popups).
    private static func bestWindow(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let axWindows = value as? [AXUIElement] else { return nil }

        // Prefer a standard window (not dialog, sheet, floating)
        return axWindows.first(where: { isStandardWindow($0) }) ?? axWindows.first
    }

    /// Check if a window is a standard, resizable window (not a dialog, sheet, or popup).
    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
        guard (roleRef as? String) == (kAXWindowRole as String) else { return false }

        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)
        let subrole = subroleRef as? String ?? ""

        // Reject dialogs, sheets, system dialogs, floating windows
        let nonStandard: Set<String> = [
            kAXDialogSubrole as String,
            kAXSystemDialogSubrole as String,
            kAXFloatingWindowSubrole as String,
            "AXSheet",
        ]
        return !nonStandard.contains(subrole)
    }

    // MARK: - Core Move with Retry & Verification

    /// Move a window to the target frame with retry and min-size clamping.
    /// This is the key difference vs. naive implementations — stubborn apps get multiple attempts.
    private static func moveWindow(_ window: AXUIElement, to target: CGRect) {
        // Query minimum size to clamp target
        let clampedTarget = clampToMinimumSize(target, window: window)

        for attempt in 0..<maxRetries {
            var position = clampedTarget.origin
            var size = clampedTarget.size

            if attempt < 2 {
                // Strategy A (attempts 0-1): position → size → position
                if let v = AXValueCreate(.cgPoint, &position) {
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
                }
                if let v = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
                }
                // Re-set position (some apps shift origin when resized)
                if let v = AXValueCreate(.cgPoint, &position) {
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
                }
            } else {
                // Strategy B (attempts 2+): size → position → size
                // Some apps (Zed, Wezterm, GPU-rendered) respond better in this order
                if let v = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
                }
                if let v = AXValueCreate(.cgPoint, &position) {
                    AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
                }
                if let v = AXValueCreate(.cgSize, &size) {
                    AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
                }
            }

            // Verify the window actually moved
            let actual = getWindowFrame(window)
            if frameMatches(actual, clampedTarget) {
                return // success
            }

            // Increasing pause between retries — stubborn apps need more time
            if attempt < maxRetries - 1 {
                usleep(UInt32((attempt + 1) * 80_000)) // 80ms, 160ms, 240ms
            }
        }
    }

    /// Clamp target frame to the window's minimum size (if reported).
    private static func clampToMinimumSize(_ target: CGRect, window: AXUIElement) -> CGRect {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, "AXMinimumSize" as CFString, &sizeRef) == .success else {
            return target
        }
        var minSize = CGSize.zero
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &minSize)

        var result = target
        if result.width < minSize.width {
            result.size.width = minSize.width
        }
        if result.height < minSize.height {
            result.size.height = minSize.height
        }
        return result
    }

    /// Read the current frame of a window.
    private static func getWindowFrame(_ window: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success else {
            return .zero
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    /// Check if actual frame matches target within tolerance.
    private static func frameMatches(_ actual: CGRect, _ target: CGRect) -> Bool {
        abs(actual.origin.x - target.origin.x) <= tolerance &&
        abs(actual.origin.y - target.origin.y) <= tolerance &&
        abs(actual.width - target.width) <= tolerance &&
        abs(actual.height - target.height) <= tolerance
    }

    // MARK: - Gaps

    /// Apply configurable gaps between windows and screen edges.
    private static func applyGaps(to frame: CGRect, in screen: CGRect, zone: LayoutZone) -> CGRect {
        let gap = gapSize
        guard gap > 0 else { return frame }

        let halfGap = gap / 2

        var x = frame.origin.x
        var y = frame.origin.y
        var w = frame.width
        var h = frame.height

        // Left edge: full gap from screen edge; otherwise half gap (shared border)
        if zone.x <= 0.001 {
            x += gap
            w -= gap + halfGap
        } else if zone.x + zone.width >= 0.999 {
            x += halfGap
            w -= gap + halfGap
        } else {
            x += halfGap
            w -= gap
        }

        // Top edge
        if zone.y <= 0.001 {
            y += gap
            h -= gap + halfGap
        } else if zone.y + zone.height >= 0.999 {
            y += halfGap
            h -= gap + halfGap
        } else {
            y += halfGap
            h -= gap
        }

        return CGRect(x: x, y: y, width: max(w, 100), height: max(h, 100))
    }

    // MARK: - Screen Helpers

    /// Convert any NSScreen's visible frame to Quartz (AX) coordinates
    /// (origin at top-left of primary display, y increases downward).
    static func quartzVisibleFrame(for screen: NSScreen) -> CGRect {
        let cocoaVisible = screen.visibleFrame
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height

        // Convert Cocoa y (bottom-up) to Quartz y (top-down)
        let quartzY = primaryHeight - cocoaVisible.origin.y - cocoaVisible.height

        return CGRect(
            x: cocoaVisible.origin.x,
            y: quartzY,
            width: cocoaVisible.width,
            height: cocoaVisible.height
        )
    }

    /// Returns the visible frame (in Quartz coords) of the screen under the mouse cursor.
    private static func bestScreen() -> CGRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return .zero }
        return quartzVisibleFrame(for: screen)
    }

    /// Compute the snap frame for a direction within a screen rect (Quartz coords).
    private static func snapFrame(for direction: SnapDirection, in screen: CGRect) -> CGRect {
        let f = direction.fractions
        let gap = gapSize

        let rawFrame = CGRect(
            x: screen.origin.x + f.x * screen.width,
            y: screen.origin.y + f.y * screen.height,
            width: f.w * screen.width,
            height: f.h * screen.height
        )

        guard gap > 0 else { return rawFrame }

        // Use the applyGaps method via a temporary LayoutZone
        let zone = LayoutZone(id: UUID(), name: "", x: f.x, y: f.y, width: f.w, height: f.h)
        return applyGaps(to: rawFrame, in: screen, zone: zone)
    }

    /// Find the Quartz visible frame of the screen a window is currently on.
    private static func screenForWindow(_ window: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success else {
            return nil
        }
        var windowOrigin = CGPoint.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &windowOrigin)

        // Window origin is in Quartz coords (top-left origin).
        // NSScreen frames are in Cocoa coords (bottom-left origin).
        // Convert window origin to Cocoa to match against NSScreen.frame.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = primaryHeight - windowOrigin.y
        let cocoaPoint = NSPoint(x: windowOrigin.x, y: cocoaY)

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cocoaPoint, $0.frame, false) }) else {
            return nil
        }
        return quartzVisibleFrame(for: screen)
    }
}
