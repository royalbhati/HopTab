import AppKit
import ApplicationServices
import QuartzCore

/// Detects window drags to screen edges/corners and snaps them.
final class DragSnapService {
    var isEnabled: Bool = false {
        didSet {
            guard oldValue != isEnabled, !isEnabled else { return }
            // Turned off mid-gesture: drop the preview and the key monitors.
            abandonGesture()
        }
    }

    // MARK: - Preferences

    /// UserDefaults key for restore-on-unsnap (default ON). When enabled,
    /// dragging a window HopTab previously snapped away from its snapped
    /// frame — without hitting a new snap zone — restores its pre-snap size
    /// with the window following the cursor (Rectangle behavior).
    /// Settings UI should bind a Toggle to this key.
    static let restoreOnUnsnapDefaultsKey = "restoreSizeOnUnsnap"

    /// UserDefaults key for the "hold this modifier to move a window to an
    /// edge WITHOUT snapping" escape hatch. Stores a `DisableModifier` raw
    /// value ("none", "control", "option", "command", "shift").
    /// Default when unset: `.control`. Settings UI should bind a Picker here.
    static let disableModifierDefaultsKey = "dragSnapDisableModifier"

    /// Modifier that suppresses drag-to-snap for the whole gesture while held.
    enum DisableModifier: String, CaseIterable {
        case none
        case control
        case option
        case command
        case shift

        var displayName: String {
            switch self {
            case .none: return "None"
            case .control: return "Control (⌃)"
            case .option: return "Option (⌥)"
            case .command: return "Command (⌘)"
            case .shift: return "Shift (⇧)"
            }
        }

        /// Flag as reported by the CGEvent mouse stream.
        var cgFlag: CGEventFlags? {
            switch self {
            case .none: return nil
            case .control: return .maskControl
            case .option: return .maskAlternate
            case .command: return .maskCommand
            case .shift: return .maskShift
            }
        }

        /// Flag as reported by NSEvent `.flagsChanged`.
        var nsFlag: NSEvent.ModifierFlags? {
            switch self {
            case .none: return nil
            case .control: return .control
            case .option: return .option
            case .command: return .command
            case .shift: return .shift
            }
        }
    }

    /// Current disable-modifier preference (defaults to Control).
    static var disableModifier: DisableModifier {
        guard let raw = UserDefaults.standard.string(forKey: disableModifierDefaultsKey),
              let modifier = DisableModifier(rawValue: raw) else { return .control }
        return modifier
    }

    /// UserDefaults key for splitting the bottom edge into first/center/last
    /// third instead of snapping to the bottom half.
    ///
    /// Defaults to **off**: dragging to the bottom edge has always meant
    /// "bottom half" in HopTab, as it does in Magnet and Rectangle, and
    /// silently changing a gesture people have muscle memory for is a
    /// regression even when the new behavior is more capable. Settings UI
    /// should bind a Toggle here.
    static let bottomEdgeThirdsDefaultsKey = "dragSnapBottomEdgeThirds"

    /// Whether the bottom edge offers thirds (opt-in) or the bottom half.
    static var bottomEdgeThirdsEnabled: Bool {
        UserDefaults.standard.object(forKey: bottomEdgeThirdsDefaultsKey) as? Bool ?? false
    }

    private var restoreOnUnsnapEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.restoreOnUnsnapDefaultsKey) as? Bool ?? true
    }

    // MARK: - macOS native edge tiling

    /// True when macOS itself tiles windows dragged to a screen edge
    /// (System Settings ▸ Desktop & Dock ▸ "Drag windows to screen edges to
    /// tile"). macOS 15+ only; always false on macOS 14.
    ///
    /// HopTab never writes to Apple's domain and never disables its own
    /// feature on the strength of this — settings should surface a warning
    /// ("macOS is also tiling on edge drag — turn one of them off") so the
    /// user picks. Cached; refreshed on app activation (the user comes back
    /// from System Settings) or via `refreshSystemTilingState()`.
    static var systemEdgeTilingEnabled: Bool {
        if let cached = cachedSystemEdgeTiling { return cached }
        let value = readSystemEdgeTiling()
        cachedSystemEdgeTiling = value
        return value
    }

    /// Re-read `com.apple.WindowManager` and update the cached value.
    static func refreshSystemTilingState() {
        cachedSystemEdgeTiling = readSystemEdgeTiling()
    }

    private static var cachedSystemEdgeTiling: Bool?

    private static func readSystemEdgeTiling() -> Bool {
        // Edge tiling shipped with macOS 15 (Sequoia); nothing to clash with
        // on macOS 14.
        guard #available(macOS 15.0, *) else { return false }
        guard let defaults = UserDefaults(suiteName: "com.apple.WindowManager") else { return false }
        // Both keys are absent until the user toggles them, and both default
        // to ON in the system UI.
        let edgeDrag = defaults.object(forKey: "EnableTilingByEdgeDrag") as? Bool ?? true
        let topDrag = defaults.object(forKey: "EnableTopTilingByEdgeDrag") as? Bool ?? true
        return edgeDrag || topDrag
    }

    // MARK: - Gesture state

    private enum State {
        case idle
        case detecting
        case dragging
        /// Gesture disqualified (resize handle, Escape, disable modifier).
        /// Stays put until the next mouse-down re-arms detection.
        case cancelled
    }
    private var state: State = .idle

    private var initialMousePos: CGPoint = .zero
    private var initialWindowFrame: CGRect = .zero
    private var draggedWindow: AXUIElement?
    private var draggedPID: pid_t = 0
    private var currentZone: SnapDirection?
    private var currentScreen: NSScreen?
    private var lastMousePos: CGPoint = .zero
    /// Increments on every mouse-down; async AX results from a previous
    /// gesture are discarded when the generation no longer matches.
    private var dragGeneration: Int = 0
    /// True while an AX detection query is running on `axQueue`.
    private var axDetectInFlight = false
    /// Disable-modifier snapshot taken at mouse-down, so the flagsChanged
    /// handler never re-reads UserDefaults mid-gesture.
    private var activeDisableModifier: DisableModifier = .control
    /// Escape / modifier monitors, installed only while a gesture is live.
    private var gestureKeyMonitors: [Any] = []

    /// Serial background queue for AX reads — the mouse event path only
    /// records positions and schedules queries; it never waits on AX.
    private let axQueue = DispatchQueue(label: "com.hoptab.DragSnapService.ax", qos: .userInteractive)
    private let axMessagingTimeout: Float = 0.3

    // Throttle drag processing to avoid burning CPU at 60-120 Hz
    private var lastDragProcessTime: CFTimeInterval = 0
    private let detectThrottleInterval: CFTimeInterval = 0.064  // ~15 Hz during AX detection
    private let draggingThrottleInterval: CFTimeInterval = 0.032 // ~30 Hz during zone checks

    private let previewController = SnapPreviewController()
    private let edgeThreshold: CGFloat = 3    // pixels from screen edge to trigger half snap
    private let cornerThreshold: CGFloat = 60 // corner zone size (px from corner)
    private let dragDetectThreshold: CGFloat = 5
    /// Slack for "the window moved" / "the window did not resize" tests.
    private let frameTolerance: CGFloat = 2
    private let escapeKeyCode: UInt16 = 53

    // MARK: - Screen snapshot (main thread only)

    /// NSScreen must never be touched from `axQueue`; the list is snapshotted
    /// on the main thread and every geometry test reads the snapshot.
    private var cachedScreens: [NSScreen] = []
    private var cachedScreenFrames: [CGRect] = []
    private var cachedPrimaryHeight: CGFloat = 0

    private var workspaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    init() {
        refreshScreenSnapshot()
        DragSnapService.refreshSystemTilingState()

        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { _ in
            DragSnapService.refreshSystemTilingState()
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshScreenSnapshot()
        }
    }

    deinit {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        for monitor in gestureKeyMonitors { NSEvent.removeMonitor(monitor) }
    }

    @discardableResult
    private func refreshScreenSnapshot() -> [NSScreen] {
        let screens = NSScreen.screens
        cachedScreens = screens
        cachedScreenFrames = screens.map { $0.frame }
        cachedPrimaryHeight = screens.first?.frame.height ?? 0
        return screens
    }

    // MARK: - Mouse Event Handler

    /// Called from the CGEvent tap callback, which runs on the main run loop.
    func handleMouseEvent(type: CGEventType, event: CGEvent) {
        guard isEnabled else { return }

        switch type {
        case .leftMouseDown:
            handleMouseDown(event)
        case .leftMouseDragged:
            handleMouseDragged(event)
        case .leftMouseUp:
            handleMouseUp(event)
        default:
            break
        }
    }

    // MARK: - State Machine

    private func handleMouseDown(_ event: CGEvent) {
        // A fresh gesture always starts from a clean slate.
        removeGestureKeyMonitors()
        previewController.hide()

        initialMousePos = event.location
        lastMousePos = event.location
        initialWindowFrame = .zero  // Reset so detection starts fresh each click
        draggedWindow = nil
        currentZone = nil
        currentScreen = nil
        lastDragProcessTime = 0
        dragGeneration += 1

        // Modifier-to-disable: let the user drop a window on an edge without
        // HopTab (or its preview) getting involved.
        activeDisableModifier = Self.disableModifier
        if let flag = activeDisableModifier.cgFlag, event.flags.contains(flag) {
            state = .cancelled
            return
        }

        // Keep the screen geometry fresh for this gesture (main thread).
        refreshScreenSnapshot()

        state = .detecting
        installGestureKeyMonitors()
    }

    private func handleMouseDragged(_ event: CGEvent) {
        let pos = event.location
        lastMousePos = pos

        switch state {
        case .idle, .cancelled:
            return

        case .detecting:
            // Check if cursor moved enough to be a drag
            let dx = pos.x - initialMousePos.x
            let dy = pos.y - initialMousePos.y
            guard (dx * dx + dy * dy) > (dragDetectThreshold * dragDetectThreshold) else { return }

            // Throttle AX detection scheduling (~15 Hz instead of 60-120 Hz)
            let now = CACurrentMediaTime()
            guard now - lastDragProcessTime >= detectThrottleInterval else { return }
            lastDragProcessTime = now

            // Schedule the AX query on the background queue — the event path
            // records positions only and never waits on AX.
            scheduleWindowDragDetection()

        case .dragging:
            // Throttle zone checks (~30 Hz — plenty for smooth preview)
            let now = CACurrentMediaTime()
            guard now - lastDragProcessTime >= draggingThrottleInterval else { return }
            lastDragProcessTime = now
            checkZone(at: pos)
        }
    }

    private func handleMouseUp(_ event: CGEvent) {
        defer {
            state = .idle
            draggedWindow = nil
            currentZone = nil
            currentScreen = nil
            dragGeneration += 1 // invalidate any in-flight AX detection
            removeGestureKeyMonitors()
            previewController.hide()
        }

        guard state == .dragging,
              let zone = currentZone,
              let window = draggedWindow,
              let screen = currentScreen
        else {
            // Drag ended with no zone hit: if the drag started from a frame
            // HopTab snapped this window to, restore its pre-snap size with
            // the window following the cursor. LayoutService checks whether
            // the start frame matches a known snapped frame — this never
            // fires for windows HopTab never snapped.
            if restoreOnUnsnapEnabled,
               state == .dragging,
               currentZone == nil,
               let window = draggedWindow,
               !initialWindowFrame.isEmpty {
                LayoutService.restoreSizeAfterUnsnap(
                    window: window,
                    pid: draggedPID,
                    dragStartFrame: initialWindowFrame,
                    cursor: event.location
                )
            }
            return
        }

        let screenFrame = LayoutService.quartzVisibleFrame(for: screen)
        // snapWindow enqueues its AX work on LayoutService's serial queue and
        // returns immediately — the mouse-up path never blocks on a move.
        LayoutService.snapWindow(window, pid: draggedPID, to: zone, on: screenFrame)
    }

    /// Disqualify the current gesture: no preview, no snap, no restore, and
    /// no re-arming until the next mouse-down.
    private func abandonGesture() {
        state = .cancelled
        draggedWindow = nil
        currentZone = nil
        currentScreen = nil
        dragGeneration += 1 // invalidate any in-flight AX detection
        removeGestureKeyMonitors()
        previewController.hide()
    }

    // MARK: - Escape / disable-modifier monitors

    /// Installed only while a gesture is live (mouse-down → mouse-up/cancel).
    /// The global monitor catches keys while another app owns the drag; the
    /// local one covers dragging one of HopTab's own windows. Neither can
    /// swallow the event, so the dragged app still sees the keystroke.
    private func installGestureKeyMonitors() {
        guard gestureKeyMonitors.isEmpty else { return }

        let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.keyDown, .flagsChanged],
            handler: { [weak self] event in
                self?.handleGestureKeyEvent(event)
            }
        )
        if let globalMonitor { gestureKeyMonitors.append(globalMonitor) }

        let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged],
            handler: { [weak self] event -> NSEvent? in
                self?.handleGestureKeyEvent(event)
                return event
            }
        )
        if let localMonitor { gestureKeyMonitors.append(localMonitor) }
    }

    private func removeGestureKeyMonitors() {
        guard !gestureKeyMonitors.isEmpty else { return }
        for monitor in gestureKeyMonitors { NSEvent.removeMonitor(monitor) }
        gestureKeyMonitors.removeAll()
    }

    private func handleGestureKeyEvent(_ event: NSEvent) {
        guard state == .detecting || state == .dragging else { return }

        switch event.type {
        case .keyDown:
            if event.keyCode == escapeKeyCode { abandonGesture() }
        case .flagsChanged:
            if let flag = activeDisableModifier.nsFlag,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(flag) {
                abandonGesture()
            }
        default:
            break
        }
    }

    // MARK: - Window Drag Detection

    /// Kick off one async AX query (focused window + frame) on the background
    /// queue. The result is applied back on the main queue if the gesture is
    /// still in the detecting phase. At most one query is in flight at a time.
    private func scheduleWindowDragDetection() {
        guard !axDetectInFlight else { return }
        axDetectInFlight = true
        let generation = dragGeneration
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            axDetectInFlight = false
            state = .idle
            return
        }
        let pid = frontApp.processIdentifier
        let timeout = axMessagingTimeout

        axQueue.async { [weak self] in
            // All AX IPC happens here, never on the event path. No AppKit
            // (NSScreen / NSEvent.mouseLocation) may be touched in this block.
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, timeout)

            var axWindow: AXUIElement?
            var frame: CGRect = .zero

            var focusedRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
               let window = focusedRef,
               CFGetTypeID(window) == AXUIElementGetTypeID() {
                let win = window as! AXUIElement
                AXUIElementSetMessagingTimeout(win, timeout)
                axWindow = win
                frame = LayoutService.windowFrame(win)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.axDetectInFlight = false
                // Stale result — the gesture ended or a new one started.
                guard generation == self.dragGeneration, self.state == .detecting else { return }
                self.applyDetectionResult(window: axWindow, frame: frame, pid: pid)
            }
        }
    }

    private func applyDetectionResult(window: AXUIElement?, frame: CGRect, pid: pid_t) {
        guard let window, !frame.isEmpty else {
            state = .idle
            return
        }

        if initialWindowFrame.isEmpty {
            // First check — store the frame and keep watching for movement
            initialWindowFrame = frame
            return
        }

        // A resize from the TOP or LEFT handle moves the origin too, so origin
        // movement alone cannot tell a move from a resize. Require the size to
        // be unchanged; otherwise this is a resize and the gesture is out.
        let sizeChanged = abs(frame.width - initialWindowFrame.width) > frameTolerance ||
                          abs(frame.height - initialWindowFrame.height) > frameTolerance
        if sizeChanged {
            abandonGesture()
            return
        }

        // If the window moved roughly with the cursor, the user is dragging it
        let windowMoved = abs(frame.origin.x - initialWindowFrame.origin.x) > frameTolerance ||
                          abs(frame.origin.y - initialWindowFrame.origin.y) > frameTolerance
        if windowMoved {
            draggedWindow = window
            draggedPID = pid
            state = .dragging
            checkZone(at: lastMousePos)
        }
    }

    // MARK: - Zone Detection

    private func checkZone(at cursorPos: CGPoint) {
        // Main thread only (the event tap runs on the main run loop); the
        // screen list comes from the snapshot taken at mouse-down.
        let screens = cachedScreens.isEmpty ? refreshScreenSnapshot() : cachedScreens
        let screenFrames = cachedScreenFrames
        let primaryHeight = cachedPrimaryHeight

        // Find which screen the cursor is on
        let cocoaY = primaryHeight - cursorPos.y
        let cocoaPoint = NSPoint(x: cursorPos.x, y: cocoaY)

        guard let screen = screens.first(where: { NSMouseInRect(cocoaPoint, $0.frame, false) }) else {
            clearZone()
            return
        }

        // Use the full screen frame (not visible) for edge detection
        // so the menu bar and Dock edges still trigger
        let screenFrame = screen.frame
        // Convert screen frame to Quartz coords
        let quartzTop = primaryHeight - screenFrame.maxY
        let quartzBottom = primaryHeight - screenFrame.minY
        let quartzLeft = screenFrame.minX
        let quartzRight = screenFrame.maxX

        let x = cursorPos.x
        let y = cursorPos.y

        // An edge shared with another display is an interior seam, not a
        // boundary: dragging across it must not flash a snap preview.
        let leftIsSeam = isInteriorSeam(.left, of: screenFrame, among: screenFrames)
        let rightIsSeam = isInteriorSeam(.right, of: screenFrame, among: screenFrames)
        let topIsSeam = isInteriorSeam(.top, of: screenFrame, among: screenFrames)
        let bottomIsSeam = isInteriorSeam(.bottom, of: screenFrame, among: screenFrames)

        let nearLeft = !leftIsSeam && x <= quartzLeft + edgeThreshold
        let nearRight = !rightIsSeam && x >= quartzRight - edgeThreshold
        let nearTop = !topIsSeam && y <= quartzTop + edgeThreshold
        let nearBottom = !bottomIsSeam && y >= quartzBottom - edgeThreshold

        let newZone: SnapDirection?

        // Corners: cursor within cornerThreshold of both edges. Corner boxes
        // are laid out first so they always beat the edge bands below.
        if nearTop && x < quartzLeft + cornerThreshold {
            newZone = .topLeft
        } else if nearTop && x > quartzRight - cornerThreshold {
            newZone = .topRight
        } else if nearBottom && x < quartzLeft + cornerThreshold {
            newZone = .bottomLeft
        } else if nearBottom && x > quartzRight - cornerThreshold {
            newZone = .bottomRight
        }
        // Edges (not corners)
        else if nearLeft {
            newZone = .left
        } else if nearRight {
            newZone = .right
        } else if nearTop {
            newZone = .full
        } else if nearBottom {
            // What the corner boxes leave of the bottom edge is split into
            // three bands: first / center / last third, full height.
            newZone = bottomBandZone(x: x, left: quartzLeft, right: quartzRight)
        } else {
            newZone = nil
        }

        if newZone != currentZone || (newZone != nil && screen != currentScreen) {
            currentZone = newZone
            currentScreen = screen

            if let zone = newZone {
                let visibleFrame = LayoutService.quartzVisibleFrame(for: screen)
                let snapRect = LayoutService.computeSnapFrame(for: zone, in: visibleFrame)
                previewController.show(rect: snapRect, on: screen)
            } else {
                previewController.hide()
            }
        }
    }

    /// Bottom-edge target. `left`/`right` are the screen's Quartz x bounds;
    /// the corner hit boxes are carved out first.
    ///
    /// Bottom half unless the user opted into thirds, so existing muscle
    /// memory keeps working after an update.
    private func bottomBandZone(x: CGFloat, left: CGFloat, right: CGFloat) -> SnapDirection {
        guard Self.bottomEdgeThirdsEnabled else { return .bottomHalf }

        let bandStart = left + cornerThreshold
        let bandEnd = right - cornerThreshold
        let bandWidth = bandEnd - bandStart
        // Screen too narrow for three bands between the corners — fall back to
        // the bottom-half target rather than offering a sliver.
        guard bandWidth > 0 else { return .bottomHalf }

        let t = (x - bandStart) / bandWidth
        if t < 1.0 / 3.0 { return .firstThird }
        if t < 2.0 / 3.0 { return .centerThird }
        return .lastThird
    }

    private func clearZone() {
        if currentZone != nil {
            currentZone = nil
            currentScreen = nil
            previewController.hide()
        }
    }

    // MARK: - Display adjacency

    private enum ScreenEdge { case left, right, top, bottom }

    /// True when another display abuts `frame` along `edge` — the edge is an
    /// interior seam of the arrangement, not the outer boundary of the
    /// desktop. Frames are Cocoa coordinates (y up).
    private func isInteriorSeam(_ edge: ScreenEdge, of frame: CGRect, among frames: [CGRect]) -> Bool {
        let touchEpsilon: CGFloat = 2 // arrangements are flush, but allow rounding
        let minOverlap: CGFloat = 1   // must actually share a stretch of that edge

        for other in frames where other != frame {
            switch edge {
            case .left:
                if abs(other.maxX - frame.minX) <= touchEpsilon,
                   span(other.minY, other.maxY, frame.minY, frame.maxY) > minOverlap { return true }
            case .right:
                if abs(other.minX - frame.maxX) <= touchEpsilon,
                   span(other.minY, other.maxY, frame.minY, frame.maxY) > minOverlap { return true }
            case .top:
                if abs(other.minY - frame.maxY) <= touchEpsilon,
                   span(other.minX, other.maxX, frame.minX, frame.maxX) > minOverlap { return true }
            case .bottom:
                if abs(other.maxY - frame.minY) <= touchEpsilon,
                   span(other.minX, other.maxX, frame.minX, frame.maxX) > minOverlap { return true }
            }
        }
        return false
    }

    /// Overlap length of two 1-D intervals (negative when disjoint).
    private func span(_ aMin: CGFloat, _ aMax: CGFloat, _ bMin: CGFloat, _ bMax: CGFloat) -> CGFloat {
        min(aMax, bMax) - max(aMin, bMin)
    }
}

// MARK: - Snap Preview Controller

final class SnapPreviewController {
    private var panel: NSPanel?
    /// Bumped by every show()/hide(). A fade-out completion only orders the
    /// panel out while its captured generation is still current, so a show()
    /// landing inside the fade can no longer be undone by the stale orderOut.
    private var generation: Int = 0

    func show(rect quartzRect: CGRect, on screen: NSScreen) {
        generation &+= 1

        // Convert Quartz rect to Cocoa screen coordinates
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaRect = CGRect(
            x: quartzRect.origin.x,
            y: primaryHeight - quartzRect.origin.y - quartzRect.height,
            width: quartzRect.width,
            height: quartzRect.height
        )

        if panel == nil {
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.ignoresMouseEvents = true
            panel = p
        }

        guard let panel else { return }

        // Create the preview content
        let previewView = NSView(frame: NSRect(origin: .zero, size: cocoaRect.size))
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        previewView.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
        previewView.layer?.borderWidth = 2
        previewView.layer?.cornerRadius = 10

        panel.contentView = previewView
        panel.setFrame(cocoaRect, display: true)

        if panel.isVisible {
            // Already on screen (possibly mid fade-out): replace any running
            // alpha animation with one that lands on full opacity now.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0
                panel.animator().alphaValue = 1
            }
            panel.alphaValue = 1
        } else {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            // Animate in
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        generation &+= 1
        let capturedGeneration = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == capturedGeneration else { return }
            self.panel?.orderOut(nil)
        })
    }
}
