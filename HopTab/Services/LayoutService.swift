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
    // Undo / Redo
    case undo, redo
    // Universal cycle
    case cycleNext, cyclePrevious
    // Adjacent-window split resizing
    case growSplit, shrinkSplit

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
        case .redo: return "Redo Snap"
        case .cycleNext: return "Cycle Next"
        case .cyclePrevious: return "Cycle Previous"
        case .growSplit: return "Grow Split"
        case .shrinkSplit: return "Shrink Split"
        }
    }

    /// Directions that produce a snap frame (excludes meta-actions).
    static var snappableDirections: [SnapDirection] {
        allCases.filter { ![.nextMonitor, .previousMonitor, .undo, .redo, .cycleNext, .cyclePrevious, .growSplit, .shrinkSplit].contains($0) }
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
        case .nextMonitor, .previousMonitor, .undo, .redo, .cycleNext, .cyclePrevious, .growSplit, .shrinkSplit:
            return (0, 0, 1, 1)
        }
    }
}

/// Resolve the CGWindowID for an AX window element. Private API, but the only
/// stable per-window key macOS offers; also bridged in HopTabPro's
/// AXWindowHelpers. Declared here because the free target can't import the
/// Pro package.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ wid: inout CGWindowID) -> AXError

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

    /// Size tolerance for apps that quantize their size (Terminal rounds to
    /// character-cell multiples). If the app "counter-offers" a nearby size,
    /// accept it instead of retrying forever.
    private static let counterOfferTolerance: CGFloat = 24

    /// AX messaging timeout (seconds) applied to every element we create, so a
    /// hung app can't stall our work queue for the default 6 seconds.
    private static let axMessagingTimeout: Float = 0.3

    // MARK: - Work Queue

    /// Serial background queue for all AX messaging. Every public entry point
    /// enqueues here and returns immediately, so the main thread (and the
    /// event tap) never waits on AX. Serial ordering preserves applyLayout's
    /// window sequencing and keeps retry waits off the main thread.
    private static let axQueue = DispatchQueue(label: "com.hoptab.LayoutService.ax", qos: .userInteractive)

    /// Create an application AX element with the short messaging timeout applied.
    private static func makeAppElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        return element
    }

    private static func applyMessagingTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
    }

    // MARK: - Undo Storage

    /// Serial queue protecting mutable static state (previousFrames, lastSnap, lastUniversalCycle).
    private static let stateQueue = DispatchQueue(label: "com.hoptab.LayoutService.state")

    /// Stores the previous frame before each snap, keyed by CGWindowID
    /// (stable per window — titles change, window IDs don't). The owning pid
    /// is kept so entries can be pruned when the app terminates.
    private static var previousFrames: [CGWindowID: (pid: pid_t, frame: CGRect)] = [:]

    /// Pre-snap state per window: the window's size before HopTab first
    /// snapped it, plus the frame HopTab last snapped it to (and the zone).
    /// Powers restore-on-unsnap (drag away → original size follows cursor)
    /// and grow/shrink split re-detection after the frame no longer matches
    /// an exact zone fraction.
    private static var preSnapStates: [CGWindowID: (pid: pid_t, size: CGSize, snappedFrame: CGRect, direction: SnapDirection?)] = [:]

    /// Loose tolerance for "is the window still at the frame we snapped it to" —
    /// wider than the strict move tolerance because counter-offering apps
    /// (Terminal etc.) settle up to `counterOfferTolerance` away.
    private static let snappedFrameMatchTolerance: CGFloat = 30

    /// Installed once: prune undo entries when their app terminates.
    private static let terminationObserver: Void = {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: nil
        ) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = app.processIdentifier
            stateQueue.async {
                previousFrames = previousFrames.filter { $0.value.pid != pid }
                preSnapStates = preSnapStates.filter { $0.value.pid != pid }
            }
        }
    }()

    /// Frame equality with an explicit tolerance (see `frameMatches` for the
    /// strict-move variant).
    private static func frameMatches(_ actual: CGRect, _ target: CGRect, tolerance tol: CGFloat) -> Bool {
        abs(actual.origin.x - target.origin.x) <= tol &&
        abs(actual.origin.y - target.origin.y) <= tol &&
        abs(actual.width - target.width) <= tol &&
        abs(actual.height - target.height) <= tol
    }

    /// Record pre-snap state before moving a window to a snap frame. Must run
    /// on `axQueue` (reads the live window frame). The original size is kept
    /// across chained snaps: if the window currently sits at the frame we last
    /// snapped it to, the stored size survives so unsnapping after several
    /// snaps still restores the true pre-snap size.
    private static func recordPreSnapState(
        _ window: AXUIElement, pid: pid_t, target: CGRect, direction: SnapDirection?
    ) {
        _ = terminationObserver
        let wid = cgWindowID(window)
        guard wid != 0 else { return }
        let current = getWindowFrame(window)
        guard !current.isEmpty else { return }
        stateQueue.sync {
            if let existing = preSnapStates[wid],
               frameMatches(current, existing.snappedFrame, tolerance: snappedFrameMatchTolerance) {
                // Still at a HopTab-snapped frame — keep the original size.
                preSnapStates[wid] = (pid: pid, size: existing.size, snappedFrame: target, direction: direction)
            } else {
                preSnapStates[wid] = (pid: pid, size: current.size, snappedFrame: target, direction: direction)
            }
        }
    }

    private static func cgWindowID(_ window: AXUIElement) -> CGWindowID {
        var wid: CGWindowID = 0
        guard _AXUIElementGetWindow(window, &wid) == .success else { return 0 }
        return wid
    }

    private static func saveFrameForUndo(_ window: AXUIElement, pid: pid_t) {
        _ = terminationObserver
        let wid = cgWindowID(window)
        guard wid != 0 else { return }
        let frame = getWindowFrame(window)
        guard !frame.isEmpty else { return }
        stateQueue.sync { previousFrames[wid] = (pid: pid, frame: frame) }
    }

    /// Restore the frontmost window to its position before the last snap.
    static func undoSnap() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier
        axQueue.async {
            let axApp = makeAppElement(pid)
            guard let axWindow = focusedOrBestWindow(of: axApp) else { return }
            let wid = cgWindowID(axWindow)
            guard wid != 0,
                  let saved = stateQueue.sync(execute: { previousFrames.removeValue(forKey: wid) })
            else { return }

            // Only restore frames that still land on a connected screen —
            // the saved frame may reference a display that's since unplugged.
            let onAScreen = NSScreen.screens.contains {
                quartzVisibleFrame(for: $0).intersects(saved.frame)
            }
            guard onAScreen else { return }
            moveWindow(axWindow, to: saved.frame)
        }
    }

    // MARK: - Cycle Through Sizes

    private static var lastSnap: (wid: CGWindowID, direction: SnapDirection, cycleIndex: Int, timestamp: Date)?

    /// Cycle sequences: pressing the same direction repeatedly cycles through these sizes.
    private static let cycleSequences: [SnapDirection: [SnapDirection]] = [
        .left:  [.left, .firstThird, .firstTwoThirds],
        .right: [.right, .lastThird, .lastTwoThirds],
        .topHalf: [.topHalf],
        .bottomHalf: [.bottomHalf],
        .full: [.full],
        .center: [.center],
    ]

    /// Resolve the actual snap direction, advancing the cycle if the same key
    /// is repeated on the same window. `isContinuation` is true when this snap
    /// continues an in-progress cycle — the undo frame is only recorded once
    /// per cycle sequence so undo returns to the true pre-snap frame.
    private static func resolvedDirection(
        for direction: SnapDirection, windowID wid: CGWindowID
    ) -> (direction: SnapDirection, isContinuation: Bool) {
        let now = Date()
        let sequence = cycleSequences[direction] ?? [direction]
        guard sequence.count > 1, wid != 0 else { return (direction, false) }

        return stateQueue.sync {
            if let last = lastSnap,
               last.wid == wid,
               last.direction == direction,
               now.timeIntervalSince(last.timestamp) < 1.5 {
                let nextIndex = (last.cycleIndex + 1) % sequence.count
                lastSnap = (wid: wid, direction: direction, cycleIndex: nextIndex, timestamp: now)
                return (sequence[nextIndex], true)
            }

            lastSnap = (wid: wid, direction: direction, cycleIndex: 0, timestamp: now)
            return (sequence[0], false)
        }
    }

    // MARK: - Universal Snap Cycle

    /// Ordered list of snap positions for universal cycling.
    private static let universalCycleOrder: [SnapDirection] = [
        .left, .right,
        .topHalf, .bottomHalf,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .firstThird, .centerThird, .lastThird,
        .firstTwoThirds, .lastTwoThirds,
        .full, .center,
    ]

    private static var lastUniversalCycle: (wid: CGWindowID, index: Int, timestamp: Date)?

    /// Detect which snap position the window currently matches, if any.
    private static func detectCurrentSnapIndex(window: AXUIElement, screen: CGRect) -> Int? {
        let currentFrame = getWindowFrame(window)
        guard !currentFrame.isEmpty else { return nil }

        for (i, direction) in universalCycleOrder.enumerated() {
            let target = snapFrame(for: direction, in: screen)
            if frameMatches(currentFrame, target) {
                return i
            }
        }
        return nil
    }

    /// Cycle the frontmost window forward or backward through all snap positions.
    static func snapFrontmostCycle(forward: Bool) {
        guard AXIsProcessTrusted() else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier

        axQueue.async {
            let axApp = makeAppElement(pid)
            guard let axWindow = focusedOrBestWindow(of: axApp) else { return }

            let screenFrame = screenForWindow(axWindow) ?? bestScreen()
            guard !screenFrame.isEmpty else { return }

            let count = universalCycleOrder.count
            let now = Date()
            let wid = cgWindowID(axWindow)

            // AX reads happen before entering the state queue —
            // keep the locked section free of IPC.
            let detectedIndex = detectCurrentSnapIndex(window: axWindow, screen: screenFrame)

            var isContinuation = false
            let nextIndex: Int = stateQueue.sync {
                let result: Int

                // If continuing a recent cycle (same window, within 1.5s), just advance
                if let last = lastUniversalCycle,
                   wid != 0,
                   last.wid == wid,
                   now.timeIntervalSince(last.timestamp) < 1.5 {
                    isContinuation = true
                    result = forward
                        ? (last.index + 1) % count
                        : (last.index - 1 + count) % count
                } else if let currentIndex = detectedIndex {
                    // Detect current position and step from there
                    result = forward
                        ? (currentIndex + 1) % count
                        : (currentIndex - 1 + count) % count
                } else {
                    // Not snapped — start at beginning or end
                    result = forward ? 0 : count - 1
                }

                lastUniversalCycle = (wid: wid, index: result, timestamp: now)
                return result
            }

            // Record the undo frame once per cycle run — repeated presses keep
            // the original pre-cycle frame so undo returns there.
            if !isContinuation {
                saveFrameForUndo(axWindow, pid: pid)
            }

            let direction = universalCycleOrder[nextIndex]
            prepareWindow(axWindow, app: axApp)
            let targetFrame = snapFrame(for: direction, in: screenFrame)
            recordPreSnapState(axWindow, pid: pid, target: targetFrame, direction: direction)
            moveWindow(axWindow, to: targetFrame, within: screenFrame)
        }
    }

    // MARK: - Apply Full Layout

    /// Apply a layout template to the active profile's pinned apps.
    /// Each zone is mapped to a bundle identifier via the binding.
    /// Returns the number of zones scheduled for layout (apps running),
    /// or -1 if AX is not trusted. The AX work itself runs asynchronously
    /// on a serial queue so this call never blocks the caller.
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

        // Resolve running apps and activate them on the calling (main) thread —
        // NSRunningApplication activation belongs there. The AX tree work and
        // settle waits happen on the serial queue.
        var zoneApps: [(zone: LayoutZone, running: NSRunningApplication)] = []
        for zone in template.zones {
            guard let bundleId = binding.zoneAssignments[zone.id] else { continue }
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { continue }

            if running.isHidden { running.unhide() }
            running.activate()

            let axApp = makeAppElement(running.processIdentifier)

            // Enable enhanced AX BEFORE trying to find windows —
            // Chrome, Zed, Electron apps won't expose their window list without this.
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, true as CFBoolean)

            zoneApps.append((zone: zone, running: running))
        }
        guard !zoneApps.isEmpty else { return 0 }

        axQueue.async {
            // Brief pause to let apps activate and expose their AX trees.
            // Without this, apps like Chrome/Zed/Wezterm silently return no
            // windows. Runs on the serial AX queue — never the main thread.
            usleep(150_000) // 150ms

            var appWindows: [(zone: LayoutZone, app: AXUIElement, window: AXUIElement)] = []
            for (zone, running) in zoneApps {
                let axApp = makeAppElement(running.processIdentifier)

                // Retry window lookup — stubborn apps sometimes need a second attempt
                var window = bestWindow(of: axApp)
                if window == nil {
                    usleep(100_000) // 100ms extra
                    window = bestWindow(of: axApp)
                }
                guard let window else { continue }
                appWindows.append((zone: zone, app: axApp, window: window))
            }

            for entry in appWindows {
                prepareWindow(entry.window, app: entry.app)

                let targetFrame = entry.zone.frame(in: screenFrame)
                let gappedFrame = applyGaps(to: targetFrame, in: screenFrame, zone: entry.zone)
                moveWindow(entry.window, to: gappedFrame, within: screenFrame)
            }

            // Raise windows in zone order (last = frontmost)
            for entry in appWindows {
                AXUIElementPerformAction(entry.window, kAXRaiseAction as CFString)
            }
        }

        return zoneApps.count
    }

    // MARK: - Quick Snap (frontmost window)

    /// Snap the frontmost window of the frontmost app to a predefined region.
    static func snapFrontmost(to direction: SnapDirection) {
        switch direction {
        case .cycleNext: snapFrontmostCycle(forward: true); return
        case .cyclePrevious: snapFrontmostCycle(forward: false); return
        case .growSplit: adjustSplit(grow: true); return
        case .shrinkSplit: adjustSplit(grow: false); return
        default: break
        }

        guard AXIsProcessTrusted() else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier

        axQueue.async {
            let axApp = makeAppElement(pid)
            guard let axWindow = focusedOrBestWindow(of: axApp) else { return }

            let screenFrame = screenForWindow(axWindow) ?? bestScreen()
            guard !screenFrame.isEmpty else { return }

            // Resolve cycling; save for undo only at the start of a cycle so
            // undo restores the true pre-snap frame.
            let resolved = resolvedDirection(for: direction, windowID: cgWindowID(axWindow))
            if !resolved.isContinuation {
                saveFrameForUndo(axWindow, pid: pid)
            }

            prepareWindow(axWindow, app: axApp)
            let targetFrame = snapFrame(for: resolved.direction, in: screenFrame)
            recordPreSnapState(axWindow, pid: pid, target: targetFrame, direction: resolved.direction)
            moveWindow(axWindow, to: targetFrame, within: screenFrame)
        }
    }

    /// Snap a specific app (by bundle ID) to a direction.
    static func snapApp(bundleIdentifier: String, to direction: SnapDirection) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }
        let pid = running.processIdentifier

        axQueue.async {
            let axApp = makeAppElement(pid)
            guard let axWindow = focusedOrBestWindow(of: axApp) else { return }

            let screenFrame = screenForWindow(axWindow) ?? bestScreen()
            guard !screenFrame.isEmpty else { return }

            let resolved = resolvedDirection(for: direction, windowID: cgWindowID(axWindow))
            if !resolved.isContinuation {
                saveFrameForUndo(axWindow, pid: pid)
            }

            prepareWindow(axWindow, app: axApp)
            let targetFrame = snapFrame(for: resolved.direction, in: screenFrame)
            recordPreSnapState(axWindow, pid: pid, target: targetFrame, direction: resolved.direction)
            moveWindow(axWindow, to: targetFrame, within: screenFrame)
            AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)

            // Only activate when the app isn't already frontmost. Otherwise we re-fire
            // `didActivateApplicationNotification`, which `WindowRulesService` listens
            // to and which re-enters `snapApp` — a ~150ms feedback loop the user sees
            // as windows "blinking" between apps. Activation happens on main.
            DispatchQueue.main.async {
                if !running.isActive {
                    running.activate()
                }
            }
        }
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
        let pid = frontApp.processIdentifier

        axQueue.async {
            let axApp = makeAppElement(pid)
            guard let axWindow = focusedOrBestWindow(of: axApp) else { return }

            let windowFrame = getWindowFrame(axWindow)
            guard !windowFrame.isEmpty else { return }

            // Max-intersection (with nearest-screen fallback) — works even when
            // the window is partially or fully off-screen.
            guard let currentScreen = nsScreenForWindowFrame(windowFrame),
                  let currentScreenIndex = screens.firstIndex(of: currentScreen) else { return }

            // Calculate target screen
            let targetIndex = ((currentScreenIndex + offset) % screens.count + screens.count) % screens.count
            let targetScreen = screens[targetIndex]

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

            saveFrameForUndo(axWindow, pid: pid)
            prepareWindow(axWindow, app: axApp)
            moveWindow(axWindow, to: newFrame, within: targetVisible)
        }
    }

    // MARK: - Window Preparation

    /// Prepare a window for snapping: unminimize, exit fullscreen.
    /// Runs on the AX queue — the animation waits never block the main thread.
    /// Note: AXEnhancedUserInterface is deliberately NOT enabled here — the
    /// window is already resolved by the time this runs (discovery paths set
    /// it themselves), and leaving it on breaks frame sets in AppKit/Chromium
    /// apps (issue #20). moveWindow disables it around each frame change.
    private static func prepareWindow(_ window: AXUIElement, app: AXUIElement) {
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
            applyMessagingTimeout(win)
            if isStandardWindow(win) { return win }
        }
        return bestWindow(of: app)
    }

    /// Find the best standard window of an app (skips dialogs, sheets, popups).
    private static func bestWindow(of app: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let axWindows = value as? [AXUIElement] else { return nil }
        for window in axWindows { applyMessagingTimeout(window) }

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
    /// This is the key difference vs. naive implementations — stubborn apps
    /// get multiple attempts. Must run on `axQueue` (the inter-attempt waits
    /// would otherwise block the main thread).
    private static func moveWindow(_ window: AXUIElement, to target: CGRect, within screen: CGRect? = nil) {
        applyMessagingTimeout(window)

        // AXEnhancedUserInterface (enabled for AX-tree discovery, or by
        // assistive tech) makes AppKit and Chromium apps animate or mis-apply
        // AX frame changes — maximize/halves land short of full height
        // (issue #20: Ghostty, Helium). Disable it on the owning app while
        // setting frames and restore it afterwards, as Rectangle does.
        var ownerPid: pid_t = 0
        var appToRestoreEnhancedUI: AXUIElement?
        if AXUIElementGetPid(window, &ownerPid) == .success, ownerPid > 0 {
            let app = makeAppElement(ownerPid)
            var enhancedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &enhancedRef) == .success,
               (enhancedRef as? Bool) == true {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, false as CFBoolean)
                appToRestoreEnhancedUI = app
            }
        }
        defer {
            if let app = appToRestoreEnhancedUI {
                AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, true as CFBoolean)
            }
        }

        // Query minimum size to clamp target; if clamping grew the frame,
        // re-anchor so the window stays within the target screen.
        var clampedTarget = clampToMinimumSize(target, window: window)
        if let screen {
            clampedTarget = reAnchor(clampedTarget, within: screen)
        }

        // Fixed-size windows can't be resized — set position once and skip
        // the retry cycle entirely (verification against size would fail forever).
        var sizeSettable: DarwinBoolean = true
        if AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable) == .success,
           !sizeSettable.boolValue {
            var position = clampedTarget.origin
            if let v = AXValueCreate(.cgPoint, &position) {
                AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
            }
            return
        }

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

            // Size-quantizing apps (Terminal rounds to row/column multiples)
            // "counter-offer" a nearby size and will never pass the strict
            // tolerance. If the position landed and the size is close, accept.
            if abs(actual.origin.x - clampedTarget.origin.x) <= tolerance,
               abs(actual.origin.y - clampedTarget.origin.y) <= tolerance,
               abs(actual.width - clampedTarget.width) <= counterOfferTolerance,
               abs(actual.height - clampedTarget.height) <= counterOfferTolerance {
                return // accepted counter-offer
            }

            // Increasing pause between retries — stubborn apps need more time.
            // Safe here: moveWindow only ever runs on the background axQueue.
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

    /// If min-size clamping grew the frame past the target zone, shift the
    /// origin so the window stays within the screen's visible frame — e.g.
    /// snapping right-half keeps the right edge on-screen.
    private static func reAnchor(_ frame: CGRect, within screen: CGRect) -> CGRect {
        var result = frame
        if result.maxX > screen.maxX { result.origin.x = screen.maxX - result.width }
        if result.origin.x < screen.origin.x { result.origin.x = screen.origin.x }
        if result.maxY > screen.maxY { result.origin.y = screen.maxY - result.height }
        if result.origin.y < screen.origin.y { result.origin.y = screen.origin.y }
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
    /// Each edge is tested independently: full gap at screen edges, half gap
    /// at shared interior edges (so adjacent zones sum to one full gap).
    private static func applyGaps(to frame: CGRect, in screen: CGRect, zone: LayoutZone) -> CGRect {
        let gap = gapSize
        guard gap > 0 else { return frame }

        let halfGap = gap / 2

        let leftInset:   CGFloat = zone.x <= 0.001 ? gap : halfGap
        let rightInset:  CGFloat = zone.x + zone.width >= 0.999 ? gap : halfGap
        let topInset:    CGFloat = zone.y <= 0.001 ? gap : halfGap
        let bottomInset: CGFloat = zone.y + zone.height >= 0.999 ? gap : halfGap

        return CGRect(
            x: frame.origin.x + leftInset,
            y: frame.origin.y + topInset,
            width: max(frame.width - leftInset - rightInset, 100),
            height: max(frame.height - topInset - bottomInset, 100)
        )
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

    /// Find the NSScreen a window frame (Quartz coords) belongs to, by
    /// maximum intersection area — origin-point tests fail for windows
    /// straddling displays or dragged partially off-screen. Falls back to the
    /// nearest screen when there's no intersection at all.
    private static func nsScreenForWindowFrame(_ windowFrame: CGRect) -> NSScreen? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        // Convert the window's Quartz frame to Cocoa for comparison.
        let cocoaWindow = CGRect(
            x: windowFrame.origin.x,
            y: primaryHeight - windowFrame.origin.y - windowFrame.height,
            width: windowFrame.width,
            height: windowFrame.height
        )

        var best: (screen: NSScreen, area: CGFloat)?
        for screen in NSScreen.screens {
            let overlap = screen.frame.intersection(cocoaWindow)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) {
                best = (screen, area)
            }
        }
        if let best { return best.screen }

        // Fully off-screen — nearest screen by center distance.
        let center = CGPoint(x: cocoaWindow.midX, y: cocoaWindow.midY)
        return NSScreen.screens.min(by: { distance(from: center, to: $0.frame) < distance(from: center, to: $1.frame) })
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    /// Find the Quartz visible frame of the screen a window is currently on.
    private static func screenForWindow(_ window: AXUIElement) -> CGRect? {
        let frame = getWindowFrame(window)
        guard !frame.isEmpty, let screen = nsScreenForWindowFrame(frame) else { return nil }
        return quartzVisibleFrame(for: screen)
    }

    // MARK: - Move App to Specific Display

    /// Move an app's main window to a named display. Used for per-display app assignments.
    static func moveAppToDisplay(bundleIdentifier: String, displayName: String) {
        guard AXIsProcessTrusted() else {
            NSLog("[LayoutService] moveAppToDisplay: AX not trusted")
            return
        }

        let screens = NSScreen.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
        guard let targetScreen = screens.first(where: { $0.localizedName == displayName }) else {
            NSLog("[LayoutService] moveAppToDisplay: display '%@' not found (available: %@)", displayName, screens.map(\.localizedName).joined(separator: ", "))
            return
        }

        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else {
            NSLog("[LayoutService] moveAppToDisplay: app %@ not running", bundleIdentifier)
            return
        }

        // Unhide if hidden (main thread — NSRunningApplication API)
        if running.isHidden { running.unhide() }
        let pid = running.processIdentifier

        axQueue.async {
            let axApp = makeAppElement(pid)
            AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, true as CFBoolean)

            // Brief pause after enabling enhanced AX (needed for Electron/Chrome).
            // Off-main: this runs on the serial AX queue.
            usleep(50_000)

            guard let axWindow = focusedOrBestWindow(of: axApp) ?? bestWindow(of: axApp) else {
                NSLog("[LayoutService] moveAppToDisplay: no window found for %@", bundleIdentifier)
                return
            }

            let currentFrame = getWindowFrame(axWindow)
            guard !currentFrame.isEmpty else {
                NSLog("[LayoutService] moveAppToDisplay: empty frame for %@", bundleIdentifier)
                return
            }

            let targetVisible = quartzVisibleFrame(for: targetScreen)

            // Skip if already on the target display
            if let currentScreenFrame = screenForWindow(axWindow),
               abs(currentScreenFrame.origin.x - targetVisible.origin.x) < 10,
               abs(currentScreenFrame.width - targetVisible.width) < 10 {
                return
            }

            // Center window on target display, clamping to fit
            let w = min(currentFrame.width, targetVisible.width)
            let h = min(currentFrame.height, targetVisible.height)
            let x = targetVisible.origin.x + (targetVisible.width - w) / 2
            let y = targetVisible.origin.y + (targetVisible.height - h) / 2
            let newFrame = CGRect(x: x, y: y, width: w, height: h)

            prepareWindow(axWindow, app: axApp)
            moveWindow(axWindow, to: newFrame, within: targetVisible)
            NSLog("[LayoutService] moveAppToDisplay: moved %@ to %@ at (%.0f,%.0f)", bundleIdentifier, displayName, newFrame.origin.x, newFrame.origin.y)
        }
    }

    // MARK: - Restore Size on Unsnap (drag away from a snapped position)

    /// Called by DragSnapService when a drag ends with no snap zone hit.
    /// If the drag started from a frame HopTab snapped this window to
    /// (Rectangle-style "unsnap"), restore the window's pre-snap SIZE with
    /// the position following the cursor: the cursor keeps roughly the same
    /// relative x within the title bar, and the title bar stays at the
    /// window's dropped height. Never fires for windows HopTab never snapped.
    /// Enqueues all AX work on the serial queue and returns immediately.
    static func restoreSizeAfterUnsnap(window: AXUIElement, pid: pid_t, dragStartFrame: CGRect, cursor: CGPoint) {
        axQueue.async {
            applyMessagingTimeout(window)
            let wid = cgWindowID(window)
            guard wid != 0 else { return }

            guard let entry = stateQueue.sync(execute: { preSnapStates[wid] }),
                  frameMatches(dragStartFrame, entry.snappedFrame, tolerance: snappedFrameMatchTolerance)
            else { return }

            let current = getWindowFrame(window)
            guard !current.isEmpty else { return }

            // Already the pre-snap size (e.g. app refused the snap resize) — nothing to do.
            let newSize = entry.size
            defer {
                // The window has left its snapped frame — it's no longer "snapped".
                _ = stateQueue.sync { preSnapStates.removeValue(forKey: wid) }
            }
            guard abs(current.width - newSize.width) > tolerance
                || abs(current.height - newSize.height) > tolerance else { return }

            // Keep the cursor at a sensible relative x within the (narrower or
            // wider) restored title bar, clamped away from the extreme edges.
            var relX = current.width > 0 ? (cursor.x - current.origin.x) / current.width : 0.5
            relX = min(max(relX, 0.1), 0.9)
            let newOrigin = CGPoint(x: cursor.x - relX * newSize.width, y: current.origin.y)
            let newFrame = CGRect(origin: newOrigin, size: newSize)

            let screen = screenForWindow(window)
            moveWindow(window, to: newFrame, within: screen)
        }
    }

    // MARK: - Adjacent-Window Split Resize (Grow / Shrink Split)

    /// Which screen edge of a snapped zone is the "inner" (shared) edge.
    private enum SplitEdge {
        case maxX, minX   // vertical split edges
        case maxY, minY   // horizontal split edges (topHalf / bottomHalf)
        var isVertical: Bool { self == .maxX || self == .minX }
    }

    /// The inner edge for each snappable direction. Quarters use their
    /// vertical (x) split edge. Center third grows/shrinks its trailing edge.
    private static func innerEdge(for direction: SnapDirection) -> SplitEdge? {
        switch direction {
        case .left, .topLeft, .bottomLeft, .firstThird, .firstTwoThirds, .centerThird:
            return .maxX
        case .right, .topRight, .bottomRight, .lastThird, .lastTwoThirds:
            return .minX
        case .topHalf:
            return .maxY
        case .bottomHalf:
            return .minY
        default:
            return nil
        }
    }

    /// How close (points) a neighbor's edge must be to the shared edge to
    /// count as abutting. Generous enough to cover configured gaps.
    private static var edgeAbutTolerance: CGFloat { max(gapSize, 0) + 10 }

    /// Grow or shrink the focused window's snapped split by moving the shared
    /// inner edge ±5% of the screen dimension, resizing abutting neighbor
    /// windows along with it (Rectangle Pro behavior). No neighbor → only the
    /// focused window's inner edge moves. The edge is bounded to 20–80% of
    /// the screen dimension. All AX work runs on the serial queue.
    static func adjustSplit(grow: Bool) {
        guard AXIsProcessTrusted() else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return }
        let pid = frontApp.processIdentifier

        axQueue.async {
            let axApp = makeAppElement(pid)
            guard let axWindow = focusedOrBestWindow(of: axApp) else { return }
            guard let screen = screenForWindow(axWindow) else { return }

            let frame = getWindowFrame(axWindow)
            guard !frame.isEmpty else { return }
            let wid = cgWindowID(axWindow)

            // Which zone is this window in? Exact fraction match first; if a
            // previous grow/shrink moved it off the exact fraction, fall back
            // to the recorded snapped frame + direction.
            var direction: SnapDirection?
            for candidate in SnapDirection.snappableDirections {
                if frameMatches(frame, snapFrame(for: candidate, in: screen), tolerance: snappedFrameMatchTolerance) {
                    direction = candidate
                    break
                }
            }
            if direction == nil, wid != 0,
               let entry = stateQueue.sync(execute: { preSnapStates[wid] }),
               frameMatches(frame, entry.snappedFrame, tolerance: snappedFrameMatchTolerance) {
                direction = entry.direction
            }
            guard let direction, let edge = innerEdge(for: direction) else { return }

            // Current shared-edge coordinate and the proposed new one.
            let currentEdge: CGFloat
            switch edge {
            case .maxX: currentEdge = frame.maxX
            case .minX: currentEdge = frame.minX
            case .maxY: currentEdge = frame.maxY
            case .minY: currentEdge = frame.minY
            }

            let span = edge.isVertical ? screen.width : screen.height
            let low = (edge.isVertical ? screen.minX : screen.minY) + 0.2 * span
            let high = (edge.isVertical ? screen.minX : screen.minY) + 0.8 * span
            let step = 0.05 * span
            // Grow moves the edge away from the focused window's interior.
            let delta: CGFloat
            switch edge {
            case .maxX, .maxY: delta = grow ? step : -step
            case .minX, .minY: delta = grow ? -step : step
            }
            let newEdge = min(max(currentEdge + delta, low), high)
            guard abs(newEdge - currentEdge) > 1 else { return }

            // Find visible neighbor windows on this screen abutting the edge.
            let neighbors = abuttingWindows(
                edge: edge, at: currentEdge, on: screen,
                excluding: wid, focusedFrame: frame
            )

            // Resize the focused window.
            let newFocused = frameByMovingEdge(frame, edge: edge, to: newEdge)
            let recordDirection = direction
            moveWindow(axWindow, to: newFocused, within: screen)
            if wid != 0 {
                // Track the adjusted frame so repeated presses (and unsnap
                // restore) keep working after the exact fraction no longer matches.
                recordSnappedFrameAfterAdjust(wid: wid, pid: pid, frame: getWindowFrame(axWindow), direction: recordDirection)
            }

            // Resize each abutting neighbor from its opposite side.
            for neighbor in neighbors {
                let nFrame = getWindowFrame(neighbor.window)
                guard !nFrame.isEmpty else { continue }
                let nEdge: SplitEdge
                switch edge {
                case .maxX: nEdge = .minX
                case .minX: nEdge = .maxX
                case .maxY: nEdge = .minY
                case .minY: nEdge = .maxY
                }
                let newNeighborFrame = frameByMovingEdge(nFrame, edge: nEdge, to: newEdge)
                moveWindow(neighbor.window, to: newNeighborFrame, within: screen)
                let nwid = cgWindowID(neighbor.window)
                if nwid != 0 {
                    recordSnappedFrameAfterAdjust(wid: nwid, pid: neighbor.pid, frame: getWindowFrame(neighbor.window), direction: nil)
                }
            }
        }
    }

    /// Update the recorded snapped frame after a split adjustment, preserving
    /// the pre-snap size when one is already stored. Only touches windows we
    /// were already tracking (or the adjusted focused window).
    private static func recordSnappedFrameAfterAdjust(wid: CGWindowID, pid: pid_t, frame: CGRect, direction: SnapDirection?) {
        guard !frame.isEmpty else { return }
        stateQueue.sync {
            if let existing = preSnapStates[wid] {
                preSnapStates[wid] = (pid: pid, size: existing.size, snappedFrame: frame, direction: direction ?? existing.direction)
            } else if direction != nil {
                preSnapStates[wid] = (pid: pid, size: frame.size, snappedFrame: frame, direction: direction)
            }
        }
    }

    /// Return a frame with one edge moved to a new coordinate.
    private static func frameByMovingEdge(_ frame: CGRect, edge: SplitEdge, to value: CGFloat) -> CGRect {
        var f = frame
        switch edge {
        case .maxX:
            f.size.width = value - f.origin.x
        case .minX:
            f.size.width = f.maxX - value
            f.origin.x = value
        case .maxY:
            f.size.height = value - f.origin.y
        case .minY:
            f.size.height = f.maxY - value
            f.origin.y = value
        }
        return f
    }

    /// Find visible standard windows on `screen` whose opposite edge abuts
    /// the shared edge (within tolerance) and which overlap the focused
    /// window's span along the edge. Uses the CGWindowList for cheap frame
    /// discovery, then resolves AX elements only for the owning apps that
    /// actually abut. Must run on `axQueue`.
    private static func abuttingWindows(
        edge: SplitEdge, at edgeValue: CGFloat, on screen: CGRect,
        excluding focusedWID: CGWindowID, focusedFrame: CGRect
    ) -> [(window: AXUIElement, pid: pid_t)] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let tol = edgeAbutTolerance
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Candidate CGWindowIDs by pid.
        var candidates: [pid_t: Set<CGWindowID>] = [:]
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != pid_t(ownPID),
                  let widNum = info[kCGWindowNumber as String] as? CGWindowID, widNum != focusedWID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            if let alpha = info[kCGWindowAlpha as String] as? CGFloat, alpha <= 0.01 { continue }

            // CGWindowList bounds are already Quartz (top-left origin).
            let bounds = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
            guard bounds.width > 50, bounds.height > 50 else { continue }
            guard screen.intersects(bounds) else { continue }

            // Opposite edge near the shared edge, with overlap along it.
            let abuts: Bool
            switch edge {
            case .maxX:
                abuts = abs(bounds.minX - edgeValue) <= tol
                    && bounds.minY < focusedFrame.maxY && bounds.maxY > focusedFrame.minY
            case .minX:
                abuts = abs(bounds.maxX - edgeValue) <= tol
                    && bounds.minY < focusedFrame.maxY && bounds.maxY > focusedFrame.minY
            case .maxY:
                abuts = abs(bounds.minY - edgeValue) <= tol
                    && bounds.minX < focusedFrame.maxX && bounds.maxX > focusedFrame.minX
            case .minY:
                abuts = abs(bounds.maxY - edgeValue) <= tol
                    && bounds.minX < focusedFrame.maxX && bounds.maxX > focusedFrame.minX
            }
            guard abuts else { continue }
            candidates[pid, default: []].insert(widNum)
        }
        guard !candidates.isEmpty else { return [] }

        // Resolve AX elements: match each candidate app's AX windows by CGWindowID.
        var result: [(window: AXUIElement, pid: pid_t)] = []
        for (pid, wids) in candidates {
            let axApp = makeAppElement(pid)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let axWindows = value as? [AXUIElement] else { continue }
            for win in axWindows {
                applyMessagingTimeout(win)
                let wwid = cgWindowID(win)
                if wids.contains(wwid), isStandardWindow(win) {
                    result.append((window: win, pid: pid))
                }
            }
        }
        return result
    }

    // MARK: - Drag-to-Snap Public API

    /// Read the current frame of a window (Quartz coordinates).
    static func windowFrame(_ window: AXUIElement) -> CGRect {
        getWindowFrame(window)
    }

    /// Compute the snap frame for a direction on a screen (Quartz coordinates).
    static func computeSnapFrame(for direction: SnapDirection, in screen: CGRect) -> CGRect {
        snapFrame(for: direction, in: screen)
    }

    /// Snap a specific AX window to a direction on a given screen. Used by
    /// drag-to-snap. Enqueues the AX work and returns immediately.
    static func snapWindow(_ window: AXUIElement, pid: pid_t, to direction: SnapDirection, on screen: CGRect) {
        axQueue.async {
            applyMessagingTimeout(window)
            saveFrameForUndo(window, pid: pid)
            let app = makeAppElement(pid)
            prepareWindow(window, app: app)
            let targetFrame = snapFrame(for: direction, in: screen)
            recordPreSnapState(window, pid: pid, target: targetFrame, direction: direction)
            moveWindow(window, to: targetFrame, within: screen)
        }
    }
}
