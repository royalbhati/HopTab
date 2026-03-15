import AppKit
import ApplicationServices

enum SnapDirection {
    case left, right, topLeft, topRight, bottomLeft, bottomRight, full
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
            guard let window = bestWindow(of: axApp) else { continue }
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

        prepareWindow(axWindow, app: axApp)
        let targetFrame = snapFrame(for: direction, in: screenFrame)
        moveWindow(axWindow, to: targetFrame)
    }

    /// Snap a specific app (by bundle ID) to a direction.
    static func snapApp(bundleIdentifier: String, to direction: SnapDirection) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }

        let axApp = AXUIElementCreateApplication(running.processIdentifier)
        guard let axWindow = focusedOrBestWindow(of: axApp) else { return }

        let screenFrame = screenForWindow(axWindow) ?? bestScreen()
        guard !screenFrame.isEmpty else { return }

        prepareWindow(axWindow, app: axApp)
        let targetFrame = snapFrame(for: direction, in: screenFrame)
        moveWindow(axWindow, to: targetFrame)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        running.activate()
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
            // Set position first (move to target origin before resizing)
            var position = clampedTarget.origin
            if let posValue = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
            }

            // Set size
            var size = clampedTarget.size
            if let sizeValue = AXValueCreate(.cgSize, &size) {
                AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
            }

            // Re-set position (some apps shift origin when resized)
            if let posValue = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posValue)
            }

            // Verify the window actually moved
            let actual = getWindowFrame(window)
            if frameMatches(actual, clampedTarget) {
                return // success
            }

            // Brief pause before retry — give the app time to process
            if attempt < maxRetries - 1 {
                usleep(50_000) // 50ms
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

    /// In Quartz coordinates: y=0 is top of screen, y increases downward.
    private static func snapFrame(for direction: SnapDirection, in screen: CGRect) -> CGRect {
        let gap = gapSize
        let w = screen.width
        let h = screen.height
        let x = screen.origin.x
        let y = screen.origin.y

        if gap > 0 {
            let halfGap = gap / 2
            switch direction {
            case .left:
                return CGRect(x: x + gap, y: y + gap, width: w / 2 - gap - halfGap, height: h - gap * 2)
            case .right:
                return CGRect(x: x + w / 2 + halfGap, y: y + gap, width: w / 2 - gap - halfGap, height: h - gap * 2)
            case .topLeft:
                return CGRect(x: x + gap, y: y + gap, width: w / 2 - gap - halfGap, height: h / 2 - gap - halfGap)
            case .topRight:
                return CGRect(x: x + w / 2 + halfGap, y: y + gap, width: w / 2 - gap - halfGap, height: h / 2 - gap - halfGap)
            case .bottomLeft:
                return CGRect(x: x + gap, y: y + h / 2 + halfGap, width: w / 2 - gap - halfGap, height: h / 2 - gap - halfGap)
            case .bottomRight:
                return CGRect(x: x + w / 2 + halfGap, y: y + h / 2 + halfGap, width: w / 2 - gap - halfGap, height: h / 2 - gap - halfGap)
            case .full:
                return CGRect(x: x + gap, y: y + gap, width: w - gap * 2, height: h - gap * 2)
            }
        }

        switch direction {
        case .left:
            return CGRect(x: x, y: y, width: w / 2, height: h)
        case .right:
            return CGRect(x: x + w / 2, y: y, width: w / 2, height: h)
        case .topLeft:
            return CGRect(x: x, y: y, width: w / 2, height: h / 2)
        case .topRight:
            return CGRect(x: x + w / 2, y: y, width: w / 2, height: h / 2)
        case .bottomLeft:
            return CGRect(x: x, y: y + h / 2, width: w / 2, height: h / 2)
        case .bottomRight:
            return CGRect(x: x + w / 2, y: y + h / 2, width: w / 2, height: h / 2)
        case .full:
            return screen
        }
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
