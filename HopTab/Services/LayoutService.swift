import AppKit
import ApplicationServices

enum SnapDirection: String, CaseIterable, Codable {
    // Halves
    case left, right, topHalf, bottomHalf
    // Quarters
    case topLeft, topRight, bottomLeft, bottomRight
    // Thirds (horizontal)
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

    // MARK: Rectangle-parity additions

    // Thirds (vertical) — power the top/bottom half size cycle
    case topThird, topTwoThirds, bottomThird, bottomTwoThirds
    // Sixths: a 3x2 grid (each 1/3 wide, 1/2 tall)
    case topLeftSixth, topCenterSixth, topRightSixth
    case bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    // Ninths: a 3x3 grid
    case topLeftNinth, topCenterNinth, topRightNinth
    case middleLeftNinth, middleCenterNinth, middleRightNinth
    case bottomLeftNinth, bottomCenterNinth, bottomRightNinth
    // Size variants
    case almostMaximize          // 92% x 92%, centered
    case centerHalf              // 50% width, full height, centered
    // Frame-relative: computed from the window's CURRENT frame, not a fraction
    case maximizeHeight          // full visible height, x/width unchanged
    case centerKeepSize          // center without resizing
    case moveLeftEdge, moveRightEdge, moveTopEdge, moveBottomEdge

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
        case .topThird: return "Top Third"
        case .topTwoThirds: return "Top Two Thirds"
        case .bottomThird: return "Bottom Third"
        case .bottomTwoThirds: return "Bottom Two Thirds"
        case .topLeftSixth: return "Top Left Sixth"
        case .topCenterSixth: return "Top Center Sixth"
        case .topRightSixth: return "Top Right Sixth"
        case .bottomLeftSixth: return "Bottom Left Sixth"
        case .bottomCenterSixth: return "Bottom Center Sixth"
        case .bottomRightSixth: return "Bottom Right Sixth"
        case .topLeftNinth: return "Top Left Ninth"
        case .topCenterNinth: return "Top Center Ninth"
        case .topRightNinth: return "Top Right Ninth"
        case .middleLeftNinth: return "Middle Left Ninth"
        case .middleCenterNinth: return "Middle Center Ninth"
        case .middleRightNinth: return "Middle Right Ninth"
        case .bottomLeftNinth: return "Bottom Left Ninth"
        case .bottomCenterNinth: return "Bottom Center Ninth"
        case .bottomRightNinth: return "Bottom Right Ninth"
        case .almostMaximize: return "Almost Maximize"
        case .centerHalf: return "Center Half"
        case .maximizeHeight: return "Maximize Height"
        case .centerKeepSize: return "Center (Keep Size)"
        case .moveLeftEdge: return "Move to Left Edge"
        case .moveRightEdge: return "Move to Right Edge"
        case .moveTopEdge: return "Move to Top Edge"
        case .moveBottomEdge: return "Move to Bottom Edge"
        }
    }

    /// Meta-actions: they trigger behaviour rather than producing a frame.
    var isMetaAction: Bool {
        switch self {
        case .nextMonitor, .previousMonitor, .undo, .redo,
             .cycleNext, .cyclePrevious, .growSplit, .shrinkSplit:
            return true
        default:
            return false
        }
    }

    /// Directions whose frame depends on the window's current frame, so
    /// `fractions` cannot describe them. `LayoutService.computeSnapFrame`
    /// needs the `current:` argument for these and returns `.zero` without it.
    var isFrameRelative: Bool {
        switch self {
        case .maximizeHeight, .centerKeepSize,
             .moveLeftEdge, .moveRightEdge, .moveTopEdge, .moveBottomEdge:
            return true
        default:
            return false
        }
    }

    /// Directions that produce a snap frame (excludes meta-actions).
    static var snappableDirections: [SnapDirection] {
        allCases.filter { !$0.isMetaAction }
    }

    /// Fractional rect (x, y, w, h) relative to screen visible frame.
    /// Meaningless for `isFrameRelative` directions (returns the full frame).
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
        // Vertical thirds
        case .topThird:       return (0,     0,     1,     1/3)
        case .topTwoThirds:   return (0,     0,     1,     2/3)
        case .bottomThird:    return (0,     2/3,   1,     1/3)
        case .bottomTwoThirds:return (0,     1/3,   1,     2/3)
        // Sixths — 3 across, 2 down
        case .topLeftSixth:      return (0,   0,   1/3, 1/2)
        case .topCenterSixth:    return (1/3, 0,   1/3, 1/2)
        case .topRightSixth:     return (2/3, 0,   1/3, 1/2)
        case .bottomLeftSixth:   return (0,   1/2, 1/3, 1/2)
        case .bottomCenterSixth: return (1/3, 1/2, 1/3, 1/2)
        case .bottomRightSixth:  return (2/3, 1/2, 1/3, 1/2)
        // Ninths — 3 across, 3 down
        case .topLeftNinth:      return (0,   0,   1/3, 1/3)
        case .topCenterNinth:    return (1/3, 0,   1/3, 1/3)
        case .topRightNinth:     return (2/3, 0,   1/3, 1/3)
        case .middleLeftNinth:   return (0,   1/3, 1/3, 1/3)
        case .middleCenterNinth: return (1/3, 1/3, 1/3, 1/3)
        case .middleRightNinth:  return (2/3, 1/3, 1/3, 1/3)
        case .bottomLeftNinth:   return (0,   2/3, 1/3, 1/3)
        case .bottomCenterNinth: return (1/3, 2/3, 1/3, 1/3)
        case .bottomRightNinth:  return (2/3, 2/3, 1/3, 1/3)
        // Size variants
        case .almostMaximize: return (0.04,  0.04,  0.92,  0.92)
        case .centerHalf:     return (0.25,  0,     0.5,   1)
        // Frame-relative and meta-actions — no fraction
        case .maximizeHeight, .centerKeepSize,
             .moveLeftEdge, .moveRightEdge, .moveTopEdge, .moveBottomEdge,
             .nextMonitor, .previousMonitor, .undo, .redo,
             .cycleNext, .cyclePrevious, .growSplit, .shrinkSplit:
            return (0, 0, 1, 1)
        }
    }
}

/// Why a snap did nothing. Reported through `LayoutService.onSnapFailure` so
/// the UI layer can surface it (a toast, a permissions prompt) — snaps used to
/// fail completely silently, including when Accessibility access was revoked.
enum SnapFailure: String, Codable, CaseIterable {
    /// Accessibility permission is missing or was revoked.
    case notTrusted
    /// No frontmost application (e.g. only the Finder desktop is active).
    case noFocusedApp
    /// The app has no standard window — only dialogs, sheets or panels.
    case noSnappableWindow
    /// No connected screen could be resolved for the window.
    case noScreen
    /// The window refused to move or resize to the requested frame.
    case windowRefusedResize

    /// Short, user-facing description. The UI layer may use its own copy.
    var message: String {
        switch self {
        case .notTrusted:        return "HopTab needs Accessibility permission to move windows."
        case .noFocusedApp:      return "No active app to snap."
        case .noSnappableWindow: return "No snappable window — only dialogs are open."
        case .noScreen:          return "No display available for this window."
        case .windowRefusedResize: return "This window refused to resize."
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

    /// Legacy single-gap default. Kept as the fallback for every per-edge gap
    /// so existing users see no change when the new keys are unset.
    static var gapSize: CGFloat {
        let saved = UserDefaults.standard.double(forKey: "windowGap")
        return saved > 0 ? saved : 0
    }

    /// Read a per-edge gap, falling back to the legacy `windowGap` value when
    /// the key has never been written.
    private static func gapValue(forKey key: String) -> CGFloat {
        guard UserDefaults.standard.object(forKey: key) != nil else { return gapSize }
        return max(CGFloat(UserDefaults.standard.double(forKey: key)), 0)
    }

    /// Gap between a snapped window and the top edge of the visible frame.
    static var gapTop: CGFloat { gapValue(forKey: "windowGapTop") }
    /// Gap between a snapped window and the bottom edge of the visible frame.
    static var gapBottom: CGFloat { gapValue(forKey: "windowGapBottom") }
    /// Gap between a snapped window and the left edge of the visible frame.
    static var gapLeft: CGFloat { gapValue(forKey: "windowGapLeft") }
    /// Gap between a snapped window and the right edge of the visible frame.
    static var gapRight: CGFloat { gapValue(forKey: "windowGapRight") }
    /// Total gap between two adjacent snapped windows (each takes half).
    static var gapInner: CGFloat { gapValue(forKey: "windowGapInner") }

    /// Maximum number of retries when a window doesn't reach the target frame.
    private static let maxRetries = 4

    /// Hard cap on how long `moveWindow` may spend retrying one window, so a
    /// window that simply cannot reach the target (System Settings enforces a
    /// minimum size) can't burn the full retry budget on every keystroke.
    private static let maxRetryWallTime: TimeInterval = 0.5

    /// Tolerance in points — if actual position is within this of target, accept it.
    private static let tolerance: CGFloat = 5

    /// Size tolerance for apps that quantize their size (Terminal rounds to
    /// character-cell multiples). If the app "counter-offers" a nearby size,
    /// accept it instead of retrying forever.
    private static let counterOfferTolerance: CGFloat = 24

    /// How long a repeated press keeps cycling the same direction.
    private static let cycleWindow: TimeInterval = 1.5

    /// AX messaging timeout (seconds) applied to every element we create, so a
    /// hung app can't stall our work queue for the default 6 seconds.
    private static let axMessagingTimeout: Float = 0.3

    // MARK: - Work Queues

    /// Serial background queue for **batch** AX work: `applyLayout`,
    /// `moveAppToDisplay`, cascade/tile, session-restore helpers. These sleep
    /// (150 ms + 100 ms settle waits) and touch many windows in sequence.
    private static let axQueue = DispatchQueue(label: "com.hoptab.LayoutService.ax", qos: .userInteractive)

    /// Serial background queue for **interactive** AX work: the user's snap
    /// keystrokes, cycling, undo, split resize, monitor moves and drag-to-snap.
    /// Split out from `axQueue` so a keystroke never queues behind a profile
    /// switch's settle sleeps, per-window retries and 700 ms fullscreen exits.
    private static let interactiveQueue = DispatchQueue(label: "com.hoptab.LayoutService.interactive", qos: .userInteractive)

    /// Create an application AX element with the short messaging timeout applied.
    private static func makeAppElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        return element
    }

    private static func applyMessagingTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
    }

    // MARK: - Screen Geometry Snapshot

    /// An immutable snapshot of the display arrangement and the mouse
    /// location, captured on the **main thread**. `NSScreen` and `NSEvent` are
    /// AppKit main-thread APIs; the AX queues used to read them directly.
    /// Every public entry point captures one of these before dispatching and
    /// passes it into the geometry helpers.
    struct ScreenGeometry {
        struct Display {
            /// `NSScreenNumber` (CGDirectDisplayID) — stable identifier.
            let number: Int
            let localizedName: String
            /// Full frame in Cocoa coordinates (bottom-left origin).
            let frame: CGRect
            /// Visible frame in Cocoa coordinates.
            let visibleFrame: CGRect
            /// Full frame in Quartz/AX coordinates (top-left origin).
            let quartzFrame: CGRect
            /// Visible frame in Quartz/AX coordinates.
            let quartzVisible: CGRect
        }

        /// Sorted left-to-right, then top-to-bottom, so stacked and mixed
        /// arrangements get a stable, intuitive "next monitor" order.
        let displays: [Display]
        /// Mouse location in Cocoa coordinates.
        let mouseLocation: CGPoint
        /// Height of the primary (menu-bar) display, for Cocoa↔Quartz flips.
        let primaryHeight: CGFloat
        /// `NSScreenNumber` of `NSScreen.main`, or -1.
        let mainNumber: Int

        var isEmpty: Bool { displays.isEmpty }

        /// Capture on the main thread. Safe to call from any thread.
        static func capture() -> ScreenGeometry {
            if Thread.isMainThread { return build() }
            return DispatchQueue.main.sync { build() }
        }

        private static func screenNumber(_ screen: NSScreen) -> Int {
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? -1
        }

        private static func build() -> ScreenGeometry {
            let screens = NSScreen.screens
            let primaryHeight = screens.first?.frame.height ?? 0
            let displays: [Display] = screens.map { screen in
                let full = screen.frame
                let visible = screen.visibleFrame
                return Display(
                    number: screenNumber(screen),
                    localizedName: screen.localizedName,
                    frame: full,
                    visibleFrame: visible,
                    quartzFrame: CGRect(
                        x: full.origin.x,
                        y: primaryHeight - full.origin.y - full.height,
                        width: full.width, height: full.height
                    ),
                    quartzVisible: CGRect(
                        x: visible.origin.x,
                        y: primaryHeight - visible.origin.y - visible.height,
                        width: visible.width, height: visible.height
                    )
                )
            }
            .sorted { a, b in
                // (E) Sort by x, then y — vertically stacked displays used to
                // sort arbitrarily because only x was compared.
                if a.frame.origin.x != b.frame.origin.x {
                    return a.frame.origin.x < b.frame.origin.x
                }
                return a.frame.origin.y < b.frame.origin.y
            }
            return ScreenGeometry(
                displays: displays,
                mouseLocation: NSEvent.mouseLocation,
                primaryHeight: primaryHeight,
                mainNumber: NSScreen.main.map(screenNumber) ?? -1
            )
        }
    }

    // MARK: - Shared Mutable State
    //
    // Two serial queues now touch this state (axQueue and interactiveQueue),
    // plus the main thread for the failure hook. Every `static var` below is
    // reached ONLY through `stateQueue`.

    /// Serial queue protecting all mutable static state.
    private static let stateQueue = DispatchQueue(label: "com.hoptab.LayoutService.state")

    /// Bounded undo **and redo** history for one window. Keyed by CGWindowID
    /// (stable per window — titles change, window IDs don't). The owning pid
    /// is kept so entries can be pruned when the app terminates.
    private struct FrameHistory {
        var pid: pid_t
        var undo: [CGRect] = []
        var redo: [CGRect] = []
    }

    /// Undo/redo stacks per window. Guarded by `stateQueue`.
    private static var frameHistory: [CGWindowID: FrameHistory] = [:]

    /// Least-recently-used order of the windows in `frameHistory`, so the map
    /// can be trimmed. Guarded by `stateQueue`.
    private static var frameHistoryOrder: [CGWindowID] = []

    /// Depth cap per window and window cap overall — a menu-bar app runs for
    /// weeks, so neither stack may grow without limit.
    private static let maxHistoryDepth = 20
    private static let maxHistoryWindows = 64

    /// Pre-snap state per window: the window's size before HopTab first
    /// snapped it, plus the frame HopTab last snapped it to (and the zone).
    /// Powers restore-on-unsnap (drag away → original size follows cursor)
    /// and grow/shrink split re-detection after the frame no longer matches
    /// an exact zone fraction.
    private static var preSnapStates: [CGWindowID: (pid: pid_t, size: CGSize, snappedFrame: CGRect, direction: SnapDirection?)] = [:]

    /// Backing storage for `onSnapFailure`. Guarded by `stateQueue`.
    private static var snapFailureHandler: ((SnapFailure, String?) -> Void)?

    /// Size-cycle tracker. Guarded by `stateQueue`.
    private static var lastSnap: (wid: CGWindowID, direction: SnapDirection, cycleIndex: Int, timestamp: Date)?

    /// Universal-cycle tracker. Guarded by `stateQueue`.
    private static var lastUniversalCycle: (wid: CGWindowID, index: Int, timestamp: Date)?

    /// Loose tolerance for "is the window still at the frame we snapped it to" —
    /// wider than the strict move tolerance because counter-offering apps
    /// (Terminal etc.) settle up to `counterOfferTolerance` away. Also used for
    /// zone *detection*, so detection and acceptance agree (see item C).
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
                frameHistory = frameHistory.filter { $0.value.pid != pid }
                frameHistoryOrder = frameHistoryOrder.filter { frameHistory[$0] != nil }
                preSnapStates = preSnapStates.filter { $0.value.pid != pid }
            }
        }
    }()

    // MARK: - Failure Reporting

    /// Called (on the **main queue**) whenever a snap does nothing. The second
    /// parameter is the app's localized name when known.
    ///
    /// Wire a toast / permissions prompt here — `LayoutService` deliberately
    /// contains no UI.
    static var onSnapFailure: ((SnapFailure, String?) -> Void)? {
        get { stateQueue.sync { snapFailureHandler } }
        set { stateQueue.sync { snapFailureHandler = newValue } }
    }

    private static func reportFailure(_ failure: SnapFailure, app: String? = nil) {
        guard let handler = stateQueue.sync(execute: { snapFailureHandler }) else { return }
        DispatchQueue.main.async { handler(failure, app) }
    }

    // MARK: - Window State (batched AX reads)

    /// Everything one snap needs to know about a window, fetched in a SINGLE
    /// AX round trip via `AXUIElementCopyMultipleAttributeValues`. Replaces the
    /// five separate reads (position, size, minimized, fullscreen, role,
    /// subrole) the old code issued per operation.
    private struct WindowState {
        var frame: CGRect
        var minimized: Bool
        var fullscreen: Bool
        var role: String
        var subrole: String

        /// A standard, snappable window — not a dialog, sheet or panel.
        var isStandard: Bool {
            guard role == (kAXWindowRole as String) else { return false }
            let nonStandard: Set<String> = [
                kAXDialogSubrole as String,
                kAXSystemDialogSubrole as String,
                kAXFloatingWindowSubrole as String,
                "AXSheet",
            ]
            return !nonStandard.contains(subrole)
        }
    }

    private static let windowStateAttributes: [String] = [
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXMinimizedAttribute as String,
        "AXFullScreen",
        kAXRoleAttribute as String,
        kAXSubroleAttribute as String,
    ]

    /// Unwrap an `AXValue` out of a multi-attribute result. Entries that
    /// couldn't be fetched come back as `kAXValueAXErrorType` placeholders.
    private static func axUnwrap<T>(_ any: CFTypeRef?, _ type: AXValueType, _ out: inout T) -> Bool {
        guard let any, CFGetTypeID(any) == AXValueGetTypeID() else { return false }
        let value = any as! AXValue
        guard AXValueGetType(value) == type else { return false }
        return AXValueGetValue(value, type, &out)
    }

    /// One round trip for the whole window state.
    private static func readWindowState(_ window: AXUIElement) -> WindowState? {
        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            window, windowStateAttributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef
        )
        guard err == .success,
              let values = valuesRef as? [CFTypeRef],
              values.count == windowStateAttributes.count
        else {
            return readWindowStateIndividually(window)
        }

        var origin = CGPoint.zero
        var size = CGSize.zero
        let gotOrigin = axUnwrap(values[0], .cgPoint, &origin)
        let gotSize = axUnwrap(values[1], .cgSize, &size)
        guard gotOrigin, gotSize else { return readWindowStateIndividually(window) }

        return WindowState(
            frame: CGRect(origin: origin, size: size),
            minimized: (values[2] as? Bool) ?? false,
            fullscreen: (values[3] as? Bool) ?? false,
            role: (values[4] as? String) ?? "",
            subrole: (values[5] as? String) ?? ""
        )
    }

    /// Fallback for apps whose AX server rejects the batched call.
    private static func readWindowStateIndividually(_ window: AXUIElement) -> WindowState? {
        let frame = readFrameIndividually(window)
        guard !frame.isEmpty else { return nil }

        var minRef: CFTypeRef?
        let minimized = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success
            && (minRef as? Bool) == true
        var fsRef: CFTypeRef?
        let fullscreen = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fsRef) == .success
            && (fsRef as? Bool) == true
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef)

        return WindowState(
            frame: frame,
            minimized: minimized,
            fullscreen: fullscreen,
            role: (roleRef as? String) ?? "",
            subrole: (subroleRef as? String) ?? ""
        )
    }

    /// Read the current frame of a window — one round trip (position + size).
    private static func getWindowFrame(_ window: AXUIElement) -> CGRect {
        var valuesRef: CFArray?
        let attrs = [kAXPositionAttribute as String, kAXSizeAttribute as String]
        let err = AXUIElementCopyMultipleAttributeValues(
            window, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef
        )
        guard err == .success, let values = valuesRef as? [CFTypeRef], values.count == 2 else {
            return readFrameIndividually(window)
        }
        var origin = CGPoint.zero
        var size = CGSize.zero
        guard axUnwrap(values[0], .cgPoint, &origin), axUnwrap(values[1], .cgSize, &size) else {
            return readFrameIndividually(window)
        }
        return CGRect(origin: origin, size: size)
    }

    private static func readFrameIndividually(_ window: AXUIElement) -> CGRect {
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

    /// Check if a window is a standard, resizable window (not a dialog, sheet, or popup).
    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        readWindowState(window)?.isStandard ?? false
    }

    // MARK: - AXEnhancedUserInterface
    //
    // (A) Assistive mode makes Chrome/Electron expose their window list, but
    // leaving it on slows their rendering and re-triggers the frame
    // misplacement of issue #20. Every site that enables it for *discovery*
    // must first read the prior value and restore exactly that value.

    private static func enhancedUIValue(_ app: AXUIElement) -> Bool? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXEnhancedUserInterface" as CFString, &ref) == .success else {
            return nil
        }
        return ref as? Bool
    }

    private static func setEnhancedUI(_ app: AXUIElement, _ value: Bool) {
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, value as CFBoolean)
    }

    // MARK: - Undo Storage

    /// Frame equality with an explicit tolerance (see `frameMatches` for the
    /// strict-move variant).
    private static func frameMatches(_ actual: CGRect, _ target: CGRect, tolerance tol: CGFloat) -> Bool {
        abs(actual.origin.x - target.origin.x) <= tol &&
        abs(actual.origin.y - target.origin.y) <= tol &&
        abs(actual.width - target.width) <= tol &&
        abs(actual.height - target.height) <= tol
    }

    /// Check if actual frame matches target within the strict move tolerance.
    private static func frameMatches(_ actual: CGRect, _ target: CGRect) -> Bool {
        frameMatches(actual, target, tolerance: tolerance)
    }

    /// Record pre-snap state before moving a window to a snap frame. Takes the
    /// already-read current frame so it costs zero AX round trips (item H).
    /// The original size is kept across chained snaps: if the window currently
    /// sits at the frame we last snapped it to, the stored size survives so
    /// unsnapping after several snaps still restores the true pre-snap size.
    private static func recordPreSnapState(
        wid: CGWindowID, pid: pid_t, current: CGRect, target: CGRect, direction: SnapDirection?
    ) {
        _ = terminationObserver
        guard wid != 0, !current.isEmpty else { return }
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

    /// Mark a window as most-recently-used and evict the oldest windows once
    /// the map exceeds `maxHistoryWindows`. Must be called on `stateQueue`.
    private static func touchHistoryLocked(_ wid: CGWindowID) {
        if let index = frameHistoryOrder.firstIndex(of: wid) {
            frameHistoryOrder.remove(at: index)
        }
        frameHistoryOrder.append(wid)
        while frameHistoryOrder.count > maxHistoryWindows {
            let evicted = frameHistoryOrder.removeFirst()
            frameHistory.removeValue(forKey: evicted)
        }
    }

    private static func trimLocked(_ stack: inout [CGRect]) {
        if stack.count > maxHistoryDepth {
            stack.removeFirst(stack.count - maxHistoryDepth)
        }
    }

    /// Push the pre-snap frame onto the undo stack. Takes the already-read
    /// frame (zero AX round trips).
    ///
    /// A new, user-initiated snap also CLEARS the redo stack — standard
    /// undo/redo semantics. `undoSnap`/`redoSnap` deliberately do not go
    /// through here, so they can move frames between the two stacks.
    private static func saveFrameForUndo(wid: CGWindowID, pid: pid_t, frame: CGRect) {
        _ = terminationObserver
        guard wid != 0, !frame.isEmpty else { return }
        stateQueue.sync {
            var entry = frameHistory[wid] ?? FrameHistory(pid: pid)
            entry.pid = pid
            entry.undo.append(frame)
            trimLocked(&entry.undo)
            entry.redo.removeAll()
            frameHistory[wid] = entry
            touchHistoryLocked(wid)
        }
    }

    /// Pop the newest undo frame, pushing the frame the window is moving away
    /// from onto the redo stack so it can be re-applied.
    private static func popUndoFrame(wid: CGWindowID, pid: pid_t, current: CGRect) -> CGRect? {
        stateQueue.sync {
            guard var entry = frameHistory[wid], let target = entry.undo.popLast() else { return nil }
            entry.pid = pid
            if !current.isEmpty {
                entry.redo.append(current)
                trimLocked(&entry.redo)
            }
            frameHistory[wid] = entry
            touchHistoryLocked(wid)
            return target
        }
    }

    /// Symmetric counterpart: pop the newest redo frame and push the frame the
    /// window is moving away from back onto the undo stack.
    private static func popRedoFrame(wid: CGWindowID, pid: pid_t, current: CGRect) -> CGRect? {
        stateQueue.sync {
            guard var entry = frameHistory[wid], let target = entry.redo.popLast() else { return nil }
            entry.pid = pid
            if !current.isEmpty {
                entry.undo.append(current)
                trimLocked(&entry.undo)
            }
            frameHistory[wid] = entry
            touchHistoryLocked(wid)
            return target
        }
    }

    /// Restore the frontmost window to its position before the last snap.
    static func undoSnap() {
        restoreHistoryFrame(redo: false)
    }

    /// Re-apply the frame the last `undoSnap()` moved away from. The free-tier
    /// counterpart to Pro's window redo — `SnapDirection.redo` ships with a
    /// default shortcut, so without this it was a dead keystroke.
    static func redoSnap() {
        restoreHistoryFrame(redo: true)
    }

    private static func restoreHistoryFrame(redo: Bool) {
        guard AXIsProcessTrusted() else { reportFailure(.notTrusted); return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            reportFailure(.noFocusedApp)
            return
        }
        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName
        let geo = ScreenGeometry.capture()

        interactiveQueue.async {
            let axApp = makeAppElement(pid)
            guard let found = discoverWindow(of: axApp) else {
                reportFailure(.noSnappableWindow, app: appName)
                return
            }
            let axWindow = found.window
            var state = found.state
            if prepareWindow(axWindow, app: axApp, state: state) {
                state.frame = getWindowFrame(axWindow)
            }

            let wid = cgWindowID(axWindow)
            guard wid != 0 else { return }
            guard let saved = redo
                ? popRedoFrame(wid: wid, pid: pid, current: state.frame)
                : popUndoFrame(wid: wid, pid: pid, current: state.frame)
            else { return }

            // Only restore frames that still land on a connected screen —
            // the saved frame may reference a display that's since unplugged.
            let onAScreen = geo.displays.contains { $0.quartzVisible.intersects(saved) }
            guard onAScreen else {
                reportFailure(.noScreen, app: appName)
                return
            }
            // No `within:` screen — undo/redo restore the EXACT saved frame
            // rather than re-anchoring it into the visible frame.
            if !moveWindow(axWindow, to: saved) {
                reportFailure(.windowRefusedResize, app: appName)
            }
        }
    }

    // MARK: - Cycle Through Sizes

    /// Cycle sequences: pressing the same direction repeatedly cycles through
    /// these sizes. Order is ½ → ⅔ → ⅓, matching Rectangle and Loop — the apps
    /// users switch from (item C).
    private static let cycleSequences: [SnapDirection: [SnapDirection]] = [
        .left:            [.left, .firstTwoThirds, .firstThird],
        .right:           [.right, .lastTwoThirds, .lastThird],
        .topHalf:         [.topHalf, .topTwoThirds, .topThird],
        .bottomHalf:      [.bottomHalf, .bottomTwoThirds, .bottomThird],
        .firstThird:      [.firstThird, .firstTwoThirds, .left],
        .lastThird:       [.lastThird, .lastTwoThirds, .right],
        .firstTwoThirds:  [.firstTwoThirds, .firstThird, .left],
        .lastTwoThirds:   [.lastTwoThirds, .lastThird, .right],
        .centerThird:     [.centerThird, .centerHalf, .center],
        .topThird:        [.topThird, .topTwoThirds, .topHalf],
        .bottomThird:     [.bottomThird, .bottomTwoThirds, .bottomHalf],
        .topTwoThirds:    [.topTwoThirds, .topThird, .topHalf],
        .bottomTwoThirds: [.bottomTwoThirds, .bottomThird, .bottomHalf],
        .full:            [.full, .almostMaximize],
        .center:          [.center, .centerHalf, .almostMaximize],
    ]

    /// Resolve the actual snap direction, advancing the cycle if the same key
    /// is repeated on the same window. `isContinuation` is true when this snap
    /// continues an in-progress cycle — the undo frame is only recorded once
    /// per cycle sequence so undo returns to the true pre-snap frame.
    ///
    /// `now` is captured on the CALLER's thread before dispatching, so a
    /// 700 ms fullscreen exit or a retry backlog can't push the gap past the
    /// cycle window (item C).
    ///
    /// Every snap is recorded, including single-entry sequences, so Left → Up
    /// → Left no longer wrongly continues the Left cycle.
    private static func resolvedDirection(
        for direction: SnapDirection, windowID wid: CGWindowID, now: Date
    ) -> (direction: SnapDirection, isContinuation: Bool) {
        let sequence = cycleSequences[direction] ?? [direction]
        guard wid != 0 else { return (direction, false) }

        return stateQueue.sync {
            if sequence.count > 1,
               let last = lastSnap,
               last.wid == wid,
               last.direction == direction,
               now.timeIntervalSince(last.timestamp) < cycleWindow {
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

    /// Detect which snap position the window currently matches, if any.
    /// Uses `snappedFrameMatchTolerance` — the same tolerance writes are
    /// accepted at — so counter-offering apps (Terminal) actually match a zone
    /// instead of restarting the cycle at 0 on every press (item C).
    private static func detectCurrentSnapIndex(currentFrame: CGRect, screen: CGRect) -> Int? {
        guard !currentFrame.isEmpty else { return nil }
        for (i, direction) in universalCycleOrder.enumerated() {
            let target = snapFrame(for: direction, in: screen, current: currentFrame)
            guard !target.isEmpty else { continue }
            if frameMatches(currentFrame, target, tolerance: snappedFrameMatchTolerance) {
                return i
            }
        }
        return nil
    }

    /// Cycle the frontmost window forward or backward through all snap positions.
    static func snapFrontmostCycle(forward: Bool) {
        guard AXIsProcessTrusted() else { reportFailure(.notTrusted); return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            reportFailure(.noFocusedApp)
            return
        }
        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName
        // Captured on the caller's thread — see resolvedDirection.
        let now = Date()
        let geo = ScreenGeometry.capture()

        interactiveQueue.async {
            let axApp = makeAppElement(pid)
            guard let found = discoverWindow(of: axApp) else {
                reportFailure(.noSnappableWindow, app: appName)
                return
            }
            let axWindow = found.window
            var state = found.state

            // Unminimize / exit fullscreen first; re-read only if it changed.
            if prepareWindow(axWindow, app: axApp, state: state) {
                state.frame = getWindowFrame(axWindow)
            }

            let screenFrame = screenForWindowFrame(state.frame, in: geo) ?? bestScreen(in: geo)
            guard !screenFrame.isEmpty else {
                reportFailure(.noScreen, app: appName)
                return
            }

            let count = universalCycleOrder.count
            let wid = cgWindowID(axWindow)

            // AX reads happen before entering the state queue —
            // keep the locked section free of IPC.
            let detectedIndex = detectCurrentSnapIndex(currentFrame: state.frame, screen: screenFrame)

            var isContinuation = false
            let nextIndex: Int = stateQueue.sync {
                let result: Int

                // If continuing a recent cycle (same window, within 1.5s), just advance
                if let last = lastUniversalCycle,
                   wid != 0,
                   last.wid == wid,
                   now.timeIntervalSince(last.timestamp) < cycleWindow {
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
                saveFrameForUndo(wid: wid, pid: pid, frame: state.frame)
            }

            let direction = universalCycleOrder[nextIndex]
            let targetFrame = snapFrame(for: direction, in: screenFrame, current: state.frame)
            guard !targetFrame.isEmpty else { return }
            recordPreSnapState(wid: wid, pid: pid, current: state.frame, target: targetFrame, direction: direction)
            if !moveWindow(axWindow, to: targetFrame, within: screenFrame) {
                reportFailure(.windowRefusedResize, app: appName)
            }
        }
    }

    // MARK: - Apply Full Layout

    /// Apply a layout template to the active profile's pinned apps.
    /// Each zone is mapped to a bundle identifier via the binding.
    /// Returns the number of zones scheduled for layout (apps running),
    /// or -1 if AX is not trusted. The AX work itself runs asynchronously
    /// on the batch queue so this call never blocks the caller.
    @discardableResult
    static func applyLayout(
        binding: LayoutBinding,
        template: LayoutTemplate,
        profile: Profile,
        screen: CGRect? = nil
    ) -> Int {
        guard AXIsProcessTrusted() else { reportFailure(.notTrusted); return -1 }

        let geo = ScreenGeometry.capture()
        let screenFrame = screen ?? bestScreen(in: geo)
        guard !screenFrame.isEmpty else { return 0 }

        // Resolve running apps and activate them on the calling (main) thread —
        // NSRunningApplication activation belongs there. The AX tree work and
        // settle waits happen on the batch queue.
        //
        // (A) AXEnhancedUserInterface is NOT enabled here any more. It used to
        // be switched on for every zone app and never switched off, leaving
        // Chrome/Electron in assistive mode for their whole lifetime. Discovery
        // below enables it only when the window list actually comes back empty,
        // and restores each app's prior value straight afterwards.
        var zoneApps: [(zone: LayoutZone, running: NSRunningApplication)] = []
        for zone in template.zones {
            guard let bundleId = binding.zoneAssignments[zone.id] else { continue }
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first else { continue }

            if running.isHidden { running.unhide() }
            running.activate()

            zoneApps.append((zone: zone, running: running))
        }
        guard !zoneApps.isEmpty else { return 0 }

        axQueue.async {
            // Brief pause to let apps activate and expose their AX trees.
            // Without this, apps like Chrome/Zed/Wezterm silently return no
            // windows. Runs on the batch queue — never the main thread.
            usleep(150_000) // 150ms

            typealias Entry = (order: Int, zone: LayoutZone, app: AXUIElement, window: AXUIElement, state: WindowState)
            var appWindows: [Entry] = []
            var pending: [(order: Int, zone: LayoutZone, app: AXUIElement)] = []

            for (index, entry) in zoneApps.enumerated() {
                let axApp = makeAppElement(entry.running.processIdentifier)
                if let found = focusedOrBestWindow(of: axApp) {
                    appWindows.append((index, entry.zone, axApp, found.window, found.state))
                } else {
                    pending.append((index, entry.zone, axApp))
                }
            }

            // Second pass for the apps that hid their window list: enable
            // assistive mode for all of them at once, pay ONE settle wait, then
            // restore each app's captured prior value.
            if !pending.isEmpty {
                var priors: [(app: AXUIElement, prior: Bool)] = []
                for entry in pending {
                    let prior = enhancedUIValue(entry.app) ?? false
                    priors.append((entry.app, prior))
                    if !prior { setEnhancedUI(entry.app, true) }
                }
                usleep(100_000) // 100ms for the AX tree to appear
                for entry in pending {
                    if let found = focusedOrBestWindow(of: entry.app) {
                        appWindows.append((entry.order, entry.zone, entry.app, found.window, found.state))
                    }
                }
                for restore in priors { setEnhancedUI(restore.app, restore.prior) }
            }

            appWindows.sort { $0.order < $1.order }

            for entry in appWindows {
                prepareWindow(entry.window, app: entry.app, state: entry.state)

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
        case .nextMonitor: moveFrontmostToNextMonitor(); return
        case .previousMonitor: moveFrontmostToPreviousMonitor(); return
        case .undo: undoSnap(); return
        case .redo: redoSnap(); return
        default: break
        }

        guard AXIsProcessTrusted() else { reportFailure(.notTrusted); return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            reportFailure(.noFocusedApp)
            return
        }
        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName
        // Captured BEFORE dispatching — see resolvedDirection (item C).
        let now = Date()
        let geo = ScreenGeometry.capture()

        // Our own windows (Settings, onboarding) must never go through AX:
        // the accessibility server for this process runs on our main thread,
        // and querying it from the AX queue crashes the app. AppKit can move
        // our own windows directly.
        if pid == ProcessInfo.processInfo.processIdentifier {
            snapOwnWindow(to: direction, geo: geo)
            return
        }

        interactiveQueue.async {
            let axApp = makeAppElement(pid)
            guard let found = discoverWindow(of: axApp) else {
                reportFailure(.noSnappableWindow, app: appName)
                return
            }
            let axWindow = found.window
            var state = found.state

            // Unminimize / exit fullscreen up front; the frame changes when it
            // does anything, so re-read it only in that case.
            if prepareWindow(axWindow, app: axApp, state: state) {
                state.frame = getWindowFrame(axWindow)
            }

            let screenFrame = screenForWindowFrame(state.frame, in: geo) ?? bestScreen(in: geo)
            guard !screenFrame.isEmpty else {
                reportFailure(.noScreen, app: appName)
                return
            }

            let wid = cgWindowID(axWindow)

            // Resolve cycling; save for undo only at the start of a cycle so
            // undo restores the true pre-snap frame.
            let resolved = resolvedDirection(for: direction, windowID: wid, now: now)
            if !resolved.isContinuation {
                saveFrameForUndo(wid: wid, pid: pid, frame: state.frame)
            }

            let targetFrame = snapFrame(for: resolved.direction, in: screenFrame, current: state.frame)
            guard !targetFrame.isEmpty else { return }
            recordPreSnapState(wid: wid, pid: pid, current: state.frame, target: targetFrame, direction: resolved.direction)
            if !moveWindow(axWindow, to: targetFrame, within: screenFrame) {
                reportFailure(.windowRefusedResize, app: appName)
            }
        }
    }

    /// Snap one of HopTab's own windows with plain AppKit (no AX round trip).
    /// Picks the key window, else the main window, else any visible titled
    /// window. Runs on the main thread.
    private static func snapOwnWindow(to direction: SnapDirection, geo: ScreenGeometry) {
        let work = {
            let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
                + NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }
            guard let window = candidates.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else {
                reportFailure(.noSnappableWindow, app: "HopTab")
                return
            }
            // Cocoa → Quartz for the shared snap math, then back.
            let cocoa = window.frame
            let current = CGRect(x: cocoa.origin.x,
                                 y: geo.primaryHeight - cocoa.origin.y - cocoa.height,
                                 width: cocoa.width, height: cocoa.height)
            let screenFrame = screenForWindowFrame(current, in: geo) ?? bestScreen(in: geo)
            guard !screenFrame.isEmpty else { reportFailure(.noScreen, app: "HopTab"); return }
            let target = snapFrame(for: direction, in: screenFrame, current: current)
            guard !target.isEmpty else { return }
            let back = NSRect(x: target.origin.x,
                              y: geo.primaryHeight - target.origin.y - target.height,
                              width: target.width, height: target.height)
            window.setFrame(back, display: true, animate: false)
        }
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Snap a specific app (by bundle ID) to a direction.
    static func snapApp(bundleIdentifier: String, to direction: SnapDirection) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }
        let pid = running.processIdentifier
        let appName = running.localizedName
        let now = Date()
        let geo = ScreenGeometry.capture()

        interactiveQueue.async {
            let axApp = makeAppElement(pid)
            guard let found = discoverWindow(of: axApp) else {
                reportFailure(.noSnappableWindow, app: appName)
                return
            }
            let axWindow = found.window
            var state = found.state

            if prepareWindow(axWindow, app: axApp, state: state) {
                state.frame = getWindowFrame(axWindow)
            }

            let screenFrame = screenForWindowFrame(state.frame, in: geo) ?? bestScreen(in: geo)
            guard !screenFrame.isEmpty else {
                reportFailure(.noScreen, app: appName)
                return
            }

            let wid = cgWindowID(axWindow)
            let resolved = resolvedDirection(for: direction, windowID: wid, now: now)
            if !resolved.isContinuation {
                saveFrameForUndo(wid: wid, pid: pid, frame: state.frame)
            }

            let targetFrame = snapFrame(for: resolved.direction, in: screenFrame, current: state.frame)
            guard !targetFrame.isEmpty else { return }
            recordPreSnapState(wid: wid, pid: pid, current: state.frame, target: targetFrame, direction: resolved.direction)
            if !moveWindow(axWindow, to: targetFrame, within: screenFrame) {
                reportFailure(.windowRefusedResize, app: appName)
            }
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

    /// Move the frontmost window to the next monitor (left-to-right, then
    /// top-to-bottom order, wrapping).
    static func moveFrontmostToNextMonitor() {
        moveFrontmostToMonitor(offset: 1)
    }

    /// Move the frontmost window to the previous monitor.
    static func moveFrontmostToPreviousMonitor() {
        moveFrontmostToMonitor(offset: -1)
    }

    private static func moveFrontmostToMonitor(offset: Int) {
        guard AXIsProcessTrusted() else { reportFailure(.notTrusted); return }
        // (E) `geo.displays` is already sorted by (x, then y).
        let geo = ScreenGeometry.capture()
        guard geo.displays.count > 1 else {
            reportFailure(.noScreen)
            return
        }

        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            reportFailure(.noFocusedApp)
            return
        }
        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName

        interactiveQueue.async {
            let axApp = makeAppElement(pid)
            guard let found = discoverWindow(of: axApp) else {
                reportFailure(.noSnappableWindow, app: appName)
                return
            }
            let axWindow = found.window
            var state = found.state
            if prepareWindow(axWindow, app: axApp, state: state) {
                state.frame = getWindowFrame(axWindow)
            }
            let windowFrame = state.frame
            guard !windowFrame.isEmpty else {
                reportFailure(.noSnappableWindow, app: appName)
                return
            }

            // Max-intersection (with nearest-screen fallback) — works even when
            // the window is partially or fully off-screen.
            guard let current = display(forWindowFrame: windowFrame, in: geo),
                  let currentIndex = geo.displays.firstIndex(where: { $0.number == current.number })
            else {
                reportFailure(.noScreen, app: appName)
                return
            }

            let count = geo.displays.count
            let targetIndex = ((currentIndex + offset) % count + count) % count
            let targetVisible = geo.displays[targetIndex].quartzVisible
            let currentVisible = current.quartzVisible

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

            saveFrameForUndo(wid: cgWindowID(axWindow), pid: pid, frame: windowFrame)
            if !moveWindow(axWindow, to: newFrame, within: targetVisible) {
                reportFailure(.windowRefusedResize, app: appName)
            }
        }
    }

    // MARK: - Window Preparation

    /// Prepare a window for snapping: unminimize, exit fullscreen. Returns
    /// true when it changed anything (so the caller knows its cached frame is
    /// stale). Runs on an AX queue — the animation waits never block main.
    ///
    /// `state` lets the caller supply an already-batched read, saving two AX
    /// round trips per snap (item H).
    ///
    /// Note: AXEnhancedUserInterface is deliberately NOT enabled here — the
    /// window is already resolved by the time this runs, and leaving it on
    /// breaks frame sets in AppKit/Chromium apps (issue #20).
    @discardableResult
    private static func prepareWindow(_ window: AXUIElement, app: AXUIElement, state: WindowState? = nil) -> Bool {
        let minimized: Bool
        let fullscreen: Bool
        if let state {
            minimized = state.minimized
            fullscreen = state.fullscreen
        } else {
            var minRef: CFTypeRef?
            minimized = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef) == .success
                && (minRef as? Bool) == true
            var fsRef: CFTypeRef?
            fullscreen = AXUIElementCopyAttributeValue(window, "AXFullScreen" as CFString, &fsRef) == .success
                && (fsRef as? Bool) == true
        }

        var changed = false
        if minimized {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFBoolean)
            usleep(200_000) // 200ms for unminimize animation
            changed = true
        }
        if fullscreen {
            AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, false as CFBoolean)
            usleep(700_000) // 700ms for fullscreen exit animation
            changed = true
        }
        return changed
    }

    // MARK: - Window Finding

    /// Find a snappable window for an app.
    ///
    /// (A) Fast path costs zero extra round trips. Only when nothing came back
    /// does it enable AXEnhancedUserInterface (Chrome/Electron hide their window
    /// list outside assistive mode) — and it restores the app's captured prior
    /// value via `defer` the moment discovery is done, so no app is left in
    /// assistive mode.
    private static func discoverWindow(
        of app: AXUIElement, settleAfterEnhance: UInt32 = 100_000
    ) -> (window: AXUIElement, state: WindowState)? {
        if let found = focusedOrBestWindow(of: app) { return found }

        let prior = enhancedUIValue(app)
        // Already in assistive mode and still nothing — there is no window.
        guard prior != true else { return nil }

        setEnhancedUI(app, true)
        defer { setEnhancedUI(app, prior ?? false) }

        if settleAfterEnhance > 0 { usleep(settleAfterEnhance) }
        return focusedOrBestWindow(of: app)
    }

    /// Get the focused window, falling back to the best standard window.
    /// Returns the batched window state alongside it (item H).
    private static func focusedOrBestWindow(of app: AXUIElement) -> (window: AXUIElement, state: WindowState)? {
        // Try the focused window first — this is what the user is looking at
        var focusedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
           let focused = focusedRef,
           CFGetTypeID(focused) == AXUIElementGetTypeID() {
            let win = focused as! AXUIElement
            applyMessagingTimeout(win)
            if let state = readWindowState(win), state.isStandard {
                return (win, state)
            }
        }
        return bestWindow(of: app)
    }

    /// Find the best standard window of an app (skips dialogs, sheets, popups).
    ///
    /// (D) There is deliberately NO fallback to `axWindows.first`: an app whose
    /// only window is a dialog used to get the dialog snapped. Returning nil
    /// lets the caller report `.noSnappableWindow`.
    private static func bestWindow(of app: AXUIElement) -> (window: AXUIElement, state: WindowState)? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let axWindows = value as? [AXUIElement] else { return nil }

        for window in axWindows {
            applyMessagingTimeout(window)
            guard let state = readWindowState(window), state.isStandard else { continue }
            return (window, state)
        }
        return nil
    }

    // MARK: - Core Move with Retry & Verification

    private static func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var value = point
        if let v = AXValueCreate(.cgPoint, &value) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, v)
        }
    }

    private static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var value = size
        if let v = AXValueCreate(.cgSize, &value) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, v)
        }
    }

    /// One write pass. Strategy A (position → size → position) suits most apps;
    /// Strategy B (size → position → size) suits Zed, Wezterm and other
    /// GPU-rendered apps.
    private static func applyFrame(_ window: AXUIElement, _ frame: CGRect, sizeFirst: Bool) {
        if sizeFirst {
            setSize(window, frame.size)
            setPosition(window, frame.origin)
            setSize(window, frame.size)
        } else {
            setPosition(window, frame.origin)
            setSize(window, frame.size)
            // Re-set position (some apps shift origin when resized)
            setPosition(window, frame.origin)
        }
    }

    /// Move a window to the target frame with retry and verification. Returns
    /// true when the window ended up at (or acceptably near) the target.
    /// Must run on an AX queue — the inter-attempt waits would otherwise block
    /// the main thread.
    ///
    /// (B) There is no minimum-size query any more. `"AXMinimumSize"` is not a
    /// real AX attribute, so the old clamp never fired; instead we read the
    /// ACTUAL frame after the writes and, if the window ended up hanging off
    /// the screen (System Settings and friends enforce a minimum width),
    /// shift the origin so it sits fully inside the visible frame.
    ///
    /// (H) The AXEnhancedUserInterface and IsAttributeSettable probes are
    /// deferred: they only run once a write has actually failed verification,
    /// so the happy path issues no probe round trips at all.
    @discardableResult
    private static func moveWindow(_ window: AXUIElement, to target: CGRect, within screen: CGRect? = nil) -> Bool {
        applyMessagingTimeout(window)

        var desired = target
        if let screen { desired = reAnchor(desired, within: screen) }

        let deadline = Date().addingTimeInterval(maxRetryWallTime)

        var probed = false
        var enhancedApp: AXUIElement?
        var enhancedPrior = false
        defer {
            // (A) Restore the CAPTURED prior value, never a hard-coded `true`.
            if let app = enhancedApp { setEnhancedUI(app, enhancedPrior) }
        }

        var actual = CGRect.zero
        var accepted = false

        for attempt in 0..<maxRetries {
            applyFrame(window, desired, sizeFirst: attempt >= 2)

            // Verify the window actually moved.
            actual = getWindowFrame(window)
            if frameMatches(actual, desired) {
                accepted = true
                break
            }

            // Size-quantizing apps (Terminal rounds to row/column multiples)
            // "counter-offer" a nearby size and will never pass the strict
            // tolerance. If the position landed and the size is close, accept.
            if abs(actual.origin.x - desired.origin.x) <= tolerance,
               abs(actual.origin.y - desired.origin.y) <= tolerance,
               abs(actual.width - desired.width) <= counterOfferTolerance,
               abs(actual.height - desired.height) <= counterOfferTolerance {
                accepted = true
                break
            }

            // Increasing pause between retries — stubborn apps need more time.
            // The wall-time cap counts the pause we are ABOUT to take, so a
            // window that can never reach the target (System Settings enforces
            // a minimum width) stops after ~260 ms instead of burning the full
            // 480 ms budget on every keystroke.
            let backoff = useconds_t((attempt + 1) * 80_000) // 80ms, 160ms, 240ms
            guard attempt < maxRetries - 1,
                  Date().addingTimeInterval(Double(backoff) / 1_000_000) < deadline
            else { break }

            if !probed {
                probed = true

                // Fixed-size windows can't be resized — set position once and
                // stop (verification against size would fail forever). The
                // caller still learns the size was refused, via the return
                // value below.
                var sizeSettable: DarwinBoolean = true
                if AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable) == .success,
                   !sizeSettable.boolValue {
                    setPosition(window, desired.origin)
                    actual = getWindowFrame(window)
                    break
                }

                // AXEnhancedUserInterface (set by real assistive tech, or left
                // on by another tool) makes AppKit and Chromium apps animate or
                // mis-apply AX frame changes — maximize/halves land short of
                // full height (issue #20: Ghostty, Helium). Turn it off for the
                // remaining attempts and restore the prior value on exit.
                var ownerPid: pid_t = 0
                if AXUIElementGetPid(window, &ownerPid) == .success, ownerPid > 0 {
                    let app = makeAppElement(ownerPid)
                    if enhancedUIValue(app) == true {
                        enhancedPrior = true
                        enhancedApp = app
                        setEnhancedUI(app, false)
                    }
                }
            }

            // Safe here: moveWindow only ever runs on a background AX queue.
            usleep(backoff)
        }

        // (B) Re-anchor against the REAL resulting frame. A window that refused
        // to shrink below its minimum width would otherwise hang off the right
        // edge of the display.
        if let screen, !actual.isEmpty {
            let anchored = reAnchor(actual, within: screen)
            if abs(anchored.origin.x - actual.origin.x) > 1 || abs(anchored.origin.y - actual.origin.y) > 1 {
                setPosition(window, anchored.origin)
                actual = CGRect(origin: anchored.origin, size: actual.size)
            }
        }

        if accepted { return true }
        // Still off-target after every retry plus the re-anchor.
        return !actual.isEmpty && frameMatches(actual, desired, tolerance: counterOfferTolerance)
    }

    /// Shift a frame's origin so it sits fully inside `screen`, preserving its
    /// size. When the frame is larger than the screen, the top-left wins.
    private static func reAnchor(_ frame: CGRect, within screen: CGRect) -> CGRect {
        var result = frame
        if result.maxX > screen.maxX { result.origin.x = screen.maxX - result.width }
        if result.origin.x < screen.origin.x { result.origin.x = screen.origin.x }
        if result.maxY > screen.maxY { result.origin.y = screen.maxY - result.height }
        if result.origin.y < screen.origin.y { result.origin.y = screen.origin.y }
        return result
    }

    // MARK: - Gaps

    /// Apply configurable gaps between windows and screen edges.
    /// Each edge is tested independently: the matching OUTER gap at screen
    /// edges, half the INNER gap at shared interior edges (so adjacent zones
    /// sum to one full inner gap).
    private static func applyGaps(to frame: CGRect, in screen: CGRect, zone: LayoutZone) -> CGRect {
        let halfInner = gapInner / 2

        let leftInset:   CGFloat = zone.x <= 0.001 ? gapLeft : halfInner
        let rightInset:  CGFloat = zone.x + zone.width >= 0.999 ? gapRight : halfInner
        let topInset:    CGFloat = zone.y <= 0.001 ? gapTop : halfInner
        let bottomInset: CGFloat = zone.y + zone.height >= 0.999 ? gapBottom : halfInner

        guard leftInset > 0 || rightInset > 0 || topInset > 0 || bottomInset > 0 else { return frame }

        return CGRect(
            x: frame.origin.x + leftInset,
            y: frame.origin.y + topInset,
            width: max(frame.width - leftInset - rightInset, 100),
            height: max(frame.height - topInset - bottomInset, 100)
        )
    }

    /// The visible frame minus the four outer gaps — the usable area for
    /// frame-relative snaps, cascading and tiling.
    private static func insetByOuterGaps(_ screen: CGRect) -> CGRect {
        CGRect(
            x: screen.minX + gapLeft,
            y: screen.minY + gapTop,
            width: max(screen.width - gapLeft - gapRight, 100),
            height: max(screen.height - gapTop - gapBottom, 100)
        )
    }

    // MARK: - Screen Helpers

    /// Convert any NSScreen's visible frame to Quartz (AX) coordinates
    /// (origin at top-left of primary display, y increases downward).
    ///
    /// Reads `NSScreen.screens`, so call it from the main thread. Background
    /// work should use the `ScreenGeometry` overload below.
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

    /// Snapshot-based overload — safe on any thread (item G).
    static func quartzVisibleFrame(for screen: NSScreen, in geometry: ScreenGeometry) -> CGRect {
        let number = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? -1
        if let display = geometry.displays.first(where: { $0.number == number }) {
            return display.quartzVisible
        }
        let cocoaVisible = screen.visibleFrame
        let primaryHeight = geometry.primaryHeight > 0 ? geometry.primaryHeight : screen.frame.height
        return CGRect(
            x: cocoaVisible.origin.x,
            y: primaryHeight - cocoaVisible.origin.y - cocoaVisible.height,
            width: cocoaVisible.width,
            height: cocoaVisible.height
        )
    }

    /// Returns the visible frame (in Quartz coords) of the screen under the
    /// mouse cursor, from a main-thread snapshot.
    private static func bestScreen(in geo: ScreenGeometry) -> CGRect {
        guard !geo.displays.isEmpty else { return .zero }
        if let under = geo.displays.first(where: { NSMouseInRect(geo.mouseLocation, $0.frame, false) }) {
            return under.quartzVisible
        }
        if let main = geo.displays.first(where: { $0.number == geo.mainNumber }) {
            return main.quartzVisible
        }
        return geo.displays[0].quartzVisible
    }

    /// Compute the snap frame for a direction within a screen rect (Quartz
    /// coords). `current` is only needed for `isFrameRelative` directions;
    /// without it they return `.zero` and callers skip them.
    private static func snapFrame(for direction: SnapDirection, in screen: CGRect, current: CGRect = .zero) -> CGRect {
        if direction.isFrameRelative {
            return relativeSnapFrame(for: direction, in: screen, current: current)
        }

        let f = direction.fractions
        let rawFrame = CGRect(
            x: screen.origin.x + f.x * screen.width,
            y: screen.origin.y + f.y * screen.height,
            width: f.w * screen.width,
            height: f.h * screen.height
        )

        // Use the applyGaps method via a temporary LayoutZone
        let zone = LayoutZone(id: UUID(), name: "", x: f.x, y: f.y, width: f.w, height: f.h)
        return applyGaps(to: rawFrame, in: screen, zone: zone)
    }

    /// Frames that depend on the window's current geometry rather than a
    /// fraction of the screen.
    private static func relativeSnapFrame(for direction: SnapDirection, in screen: CGRect, current: CGRect) -> CGRect {
        guard !current.isEmpty else { return .zero }
        let inner = insetByOuterGaps(screen)

        switch direction {
        case .maximizeHeight:
            return CGRect(x: current.origin.x, y: inner.minY, width: current.width, height: inner.height)
        case .centerKeepSize:
            return CGRect(
                x: inner.midX - current.width / 2,
                y: inner.midY - current.height / 2,
                width: current.width, height: current.height
            )
        case .moveLeftEdge:
            return CGRect(x: inner.minX, y: current.origin.y, width: current.width, height: current.height)
        case .moveRightEdge:
            return CGRect(x: inner.maxX - current.width, y: current.origin.y, width: current.width, height: current.height)
        case .moveTopEdge:
            return CGRect(x: current.origin.x, y: inner.minY, width: current.width, height: current.height)
        case .moveBottomEdge:
            return CGRect(x: current.origin.x, y: inner.maxY - current.height, width: current.width, height: current.height)
        default:
            return .zero
        }
    }

    /// Find the display a window frame (Quartz coords) belongs to, by maximum
    /// intersection area — origin-point tests fail for windows straddling
    /// displays or dragged partially off-screen. Falls back to the nearest
    /// display when there's no intersection at all.
    private static func display(forWindowFrame windowFrame: CGRect, in geo: ScreenGeometry) -> ScreenGeometry.Display? {
        var best: (display: ScreenGeometry.Display, area: CGFloat)?
        for display in geo.displays {
            let overlap = display.quartzFrame.intersection(windowFrame)
            guard !overlap.isNull, !overlap.isEmpty else { continue }
            let area = overlap.width * overlap.height
            if area > (best?.area ?? 0) {
                best = (display, area)
            }
        }
        if let best { return best.display }

        // Fully off-screen — nearest display by center distance.
        let center = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        return geo.displays.min(by: {
            distance(from: center, to: $0.quartzFrame) < distance(from: center, to: $1.quartzFrame)
        })
    }

    private static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return dx * dx + dy * dy
    }

    /// Find the Quartz visible frame of the screen an already-read window
    /// frame sits on.
    private static func screenForWindowFrame(_ frame: CGRect, in geo: ScreenGeometry) -> CGRect? {
        guard !frame.isEmpty, let display = display(forWindowFrame: frame, in: geo) else { return nil }
        return display.quartzVisible
    }

    // MARK: - Move App to Specific Display

    /// Move an app's main window to a named display. Used for per-display app assignments.
    static func moveAppToDisplay(bundleIdentifier: String, displayName: String) {
        guard AXIsProcessTrusted() else {
            NSLog("[LayoutService] moveAppToDisplay: AX not trusted")
            reportFailure(.notTrusted)
            return
        }

        let geo = ScreenGeometry.capture()
        guard let targetDisplay = geo.displays.first(where: { $0.localizedName == displayName }) else {
            NSLog("[LayoutService] moveAppToDisplay: display '%@' not found (available: %@)",
                  displayName, geo.displays.map(\.localizedName).joined(separator: ", "))
            reportFailure(.noScreen)
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

            // (A) Discovery enables AXEnhancedUserInterface only if the window
            // list came back empty, and restores the app's prior value.
            guard let found = discoverWindow(of: axApp, settleAfterEnhance: 50_000) else {
                NSLog("[LayoutService] moveAppToDisplay: no window found for %@", bundleIdentifier)
                return
            }
            let axWindow = found.window
            var state = found.state

            if prepareWindow(axWindow, app: axApp, state: state) {
                state.frame = getWindowFrame(axWindow)
            }

            let currentFrame = state.frame
            guard !currentFrame.isEmpty else {
                NSLog("[LayoutService] moveAppToDisplay: empty frame for %@", bundleIdentifier)
                return
            }

            let targetVisible = targetDisplay.quartzVisible

            // Skip if already on the target display
            if let currentScreenFrame = screenForWindowFrame(currentFrame, in: geo),
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

            moveWindow(axWindow, to: newFrame, within: targetVisible)
            NSLog("[LayoutService] moveAppToDisplay: moved %@ to %@ at (%.0f,%.0f)",
                  bundleIdentifier, displayName, newFrame.origin.x, newFrame.origin.y)
        }
    }

    // MARK: - Cascade & Tile

    /// A visible, standard, non-minimized window discovered through the
    /// CGWindowList (front-to-back order) and resolved to an AX element.
    private struct DiscoveredWindow {
        let window: AXUIElement
        let pid: pid_t
        let wid: CGWindowID
        let state: WindowState
    }

    /// Enumerate the visible standard windows sitting on `screen`, front to
    /// back. `ownedBy` restricts the result to a single app. Must run on an AX
    /// queue.
    private static func visibleStandardWindows(on screen: CGRect, ownedBy owner: pid_t?) -> [DiscoveredWindow] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        let ownPID = pid_t(ProcessInfo.processInfo.processIdentifier)

        // CGWindowList is already front-to-back; keep that order.
        var ordered: [(wid: CGWindowID, pid: pid_t)] = []
        var byPID: [pid_t: Set<CGWindowID>] = [:]
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { continue }
            if let owner, pid != owner { continue }
            if let alpha = info[kCGWindowAlpha as String] as? CGFloat, alpha <= 0.01 { continue }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0, y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0, height: boundsDict["Height"] ?? 0
            )
            guard bounds.width > 50, bounds.height > 50 else { continue }
            guard screen.intersects(bounds) else { continue }

            ordered.append((wid, pid))
            byPID[pid, default: []].insert(wid)
        }
        guard !ordered.isEmpty else { return [] }

        // Resolve AX elements once per app, matched by CGWindowID.
        var resolved: [CGWindowID: DiscoveredWindow] = [:]
        for (pid, wids) in byPID {
            let axApp = makeAppElement(pid)
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
                  let axWindows = value as? [AXUIElement] else { continue }
            for win in axWindows {
                applyMessagingTimeout(win)
                let wwid = cgWindowID(win)
                guard wids.contains(wwid),
                      let state = readWindowState(win),
                      state.isStandard, !state.minimized else { continue }
                resolved[wwid] = DiscoveredWindow(window: win, pid: pid, wid: wwid, state: state)
            }
        }

        return ordered.compactMap { resolved[$0.wid] }
    }

    /// Stagger windows from the top-left of the visible frame in ~30 pt steps,
    /// each sized to ~70% of the usable area. `appOnly` limits it to the
    /// frontmost app's windows; otherwise every app's windows on the active
    /// screen are cascaded. Runs on the batch queue and respects the gaps.
    static func cascadeWindows(appOnly: Bool) {
        guard AXIsProcessTrusted() else { reportFailure(.notTrusted); return }

        let geo = ScreenGeometry.capture()
        let screen = bestScreen(in: geo)
        guard !screen.isEmpty else { reportFailure(.noScreen); return }

        var owner: pid_t?
        var appName: String?
        if appOnly {
            guard let front = NSWorkspace.shared.frontmostApplication else {
                reportFailure(.noFocusedApp)
                return
            }
            owner = front.processIdentifier
            appName = front.localizedName
        }
        let ownerPID = owner
        let ownerName = appName

        axQueue.async {
            let windows = visibleStandardWindows(on: screen, ownedBy: ownerPID)
            guard !windows.isEmpty else {
                reportFailure(.noSnappableWindow, app: ownerName)
                return
            }

            let inner = insetByOuterGaps(screen)
            let width = inner.width * 0.7
            let height = inner.height * 0.7
            let step: CGFloat = 30
            let stepsX = Int(max(inner.width - width, 0) / step)
            let stepsY = Int(max(inner.height - height, 0) / step)
            let maxStep = max(min(stepsX, stepsY), 0)

            for (index, entry) in windows.enumerated() {
                let offset = maxStep > 0 ? CGFloat(index % (maxStep + 1)) : 0
                let frame = CGRect(
                    x: inner.minX + offset * step,
                    y: inner.minY + offset * step,
                    width: width, height: height
                )
                let axApp = makeAppElement(entry.pid)
                prepareWindow(entry.window, app: axApp, state: entry.state)
                saveFrameForUndo(wid: entry.wid, pid: entry.pid, frame: entry.state.frame)
                recordPreSnapState(wid: entry.wid, pid: entry.pid, current: entry.state.frame, target: frame, direction: nil)
                moveWindow(entry.window, to: frame, within: screen)
            }

            // Raise in cascade order (last = frontmost) so every window's
            // title bar peeks out above the one in front of it — the classic
            // staircase. Raising the other way round would hide them.
            for entry in windows {
                AXUIElementPerformAction(entry.window, kAXRaiseAction as CFString)
            }
        }
    }

    /// Tile every standard, non-minimized window on the active screen into
    /// even columns (`columns: true`) or rows. Runs on the batch queue and
    /// respects the outer gaps plus `gapInner` between neighbours.
    static func tileAllWindows(columns: Bool) {
        guard AXIsProcessTrusted() else { reportFailure(.notTrusted); return }

        let geo = ScreenGeometry.capture()
        let screen = bestScreen(in: geo)
        guard !screen.isEmpty else { reportFailure(.noScreen); return }

        axQueue.async {
            let windows = visibleStandardWindows(on: screen, ownedBy: nil)
            guard !windows.isEmpty else {
                reportFailure(.noSnappableWindow)
                return
            }

            let inner = insetByOuterGaps(screen)
            let count = CGFloat(windows.count)
            let between = gapInner

            for (index, entry) in windows.enumerated() {
                let frame: CGRect
                if columns {
                    let width = max((inner.width - between * (count - 1)) / count, 100)
                    frame = CGRect(
                        x: inner.minX + CGFloat(index) * (width + between),
                        y: inner.minY, width: width, height: inner.height
                    )
                } else {
                    let height = max((inner.height - between * (count - 1)) / count, 100)
                    frame = CGRect(
                        x: inner.minX,
                        y: inner.minY + CGFloat(index) * (height + between),
                        width: inner.width, height: height
                    )
                }

                let axApp = makeAppElement(entry.pid)
                prepareWindow(entry.window, app: axApp, state: entry.state)
                saveFrameForUndo(wid: entry.wid, pid: entry.pid, frame: entry.state.frame)
                recordPreSnapState(wid: entry.wid, pid: entry.pid, current: entry.state.frame, target: frame, direction: nil)
                moveWindow(entry.window, to: frame, within: screen)
            }
        }
    }

    // MARK: - Restore Size on Unsnap (drag away from a snapped position)

    /// Called by DragSnapService when a drag ends with no snap zone hit.
    /// If the drag started from a frame HopTab snapped this window to
    /// (Rectangle-style "unsnap"), restore the window's pre-snap SIZE with
    /// the position following the cursor: the cursor keeps roughly the same
    /// relative x within the title bar, and the title bar stays at the
    /// window's dropped height. Never fires for windows HopTab never snapped.
    /// Enqueues all AX work on the interactive queue and returns immediately.
    static func restoreSizeAfterUnsnap(window: AXUIElement, pid: pid_t, dragStartFrame: CGRect, cursor: CGPoint) {
        let geo = ScreenGeometry.capture()

        interactiveQueue.async {
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

            let screen = screenForWindowFrame(current, in: geo)
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
        case .left, .topLeft, .bottomLeft, .firstThird, .firstTwoThirds, .centerThird, .centerHalf,
             .topLeftSixth, .bottomLeftSixth, .topCenterSixth, .bottomCenterSixth,
             .topLeftNinth, .middleLeftNinth, .bottomLeftNinth,
             .topCenterNinth, .middleCenterNinth, .bottomCenterNinth:
            return .maxX
        case .right, .topRight, .bottomRight, .lastThird, .lastTwoThirds,
             .topRightSixth, .bottomRightSixth,
             .topRightNinth, .middleRightNinth, .bottomRightNinth:
            return .minX
        case .topHalf, .topThird, .topTwoThirds:
            return .maxY
        case .bottomHalf, .bottomThird, .bottomTwoThirds:
            return .minY
        default:
            return nil
        }
    }

    /// How close (points) a neighbor's edge must be to the shared edge to
    /// count as abutting. Generous enough to cover configured gaps.
    private static var edgeAbutTolerance: CGFloat {
        max(max(gapInner, gapSize), 0) + 10
    }

    /// Grow or shrink the focused window's snapped split by moving the shared
    /// inner edge ±5% of the screen dimension, resizing abutting neighbor
    /// windows along with it (Rectangle Pro behavior). No neighbor → only the
    /// focused window's inner edge moves. The edge is bounded to 20–80% of
    /// the screen dimension. All AX work runs on the interactive queue.
    static func adjustSplit(grow: Bool) {
        guard AXIsProcessTrusted() else { reportFailure(.notTrusted); return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            reportFailure(.noFocusedApp)
            return
        }
        let pid = frontApp.processIdentifier
        let appName = frontApp.localizedName
        let geo = ScreenGeometry.capture()

        interactiveQueue.async {
            let axApp = makeAppElement(pid)
            guard let found = discoverWindow(of: axApp) else {
                reportFailure(.noSnappableWindow, app: appName)
                return
            }
            let axWindow = found.window
            let frame = found.state.frame
            guard !frame.isEmpty else {
                reportFailure(.noSnappableWindow, app: appName)
                return
            }
            guard let screen = screenForWindowFrame(frame, in: geo) else {
                reportFailure(.noScreen, app: appName)
                return
            }
            let wid = cgWindowID(axWindow)

            // Which zone is this window in? Exact fraction match first; if a
            // previous grow/shrink moved it off the exact fraction, fall back
            // to the recorded snapped frame + direction.
            var direction: SnapDirection?
            for candidate in SnapDirection.snappableDirections {
                let candidateFrame = snapFrame(for: candidate, in: screen)
                guard !candidateFrame.isEmpty else { continue }
                if frameMatches(frame, candidateFrame, tolerance: snappedFrameMatchTolerance) {
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
            if !moveWindow(axWindow, to: newFocused, within: screen) {
                reportFailure(.windowRefusedResize, app: appName)
            }
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
    /// actually abut. Must run on an AX queue.
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
    /// `current` is only needed for frame-relative directions
    /// (`SnapDirection.isFrameRelative`); they return `.zero` without it.
    static func computeSnapFrame(for direction: SnapDirection, in screen: CGRect, current: CGRect = .zero) -> CGRect {
        snapFrame(for: direction, in: screen, current: current)
    }

    /// Snap a specific AX window to a direction on a given screen. Used by
    /// drag-to-snap. Enqueues the AX work on the interactive queue and returns
    /// immediately.
    static func snapWindow(_ window: AXUIElement, pid: pid_t, to direction: SnapDirection, on screen: CGRect) {
        interactiveQueue.async {
            applyMessagingTimeout(window)
            let app = makeAppElement(pid)

            guard var state = readWindowState(window) else { return }
            if prepareWindow(window, app: app, state: state) {
                state.frame = getWindowFrame(window)
            }
            guard !state.frame.isEmpty else { return }

            let wid = cgWindowID(window)
            saveFrameForUndo(wid: wid, pid: pid, frame: state.frame)

            let targetFrame = snapFrame(for: direction, in: screen, current: state.frame)
            guard !targetFrame.isEmpty else { return }
            recordPreSnapState(wid: wid, pid: pid, current: state.frame, target: targetFrame, direction: direction)
            moveWindow(window, to: targetFrame, within: screen)
        }
    }
}
