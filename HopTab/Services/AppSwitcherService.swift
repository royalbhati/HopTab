import AppKit
import ApplicationServices

struct WindowInfo: Identifiable {
    let id: CGWindowID   // stable CGWindowID (kCGWindowNumber)
    let title: String
    let isMinimized: Bool
    let spaceID: Int?    // nil for minimized windows (they live in the Dock, not on a Space)
}

enum AppSwitcherService {

    // MARK: - AX Plumbing
    //
    // HopTab's CGEvent tap run-loop source lives on the MAIN run loop, so any
    // synchronous AX round trip on the main thread stalls the keyboard for the
    // whole system. Two rules follow, and every entry point below obeys them:
    //
    //   1. Every AX element this file creates gets a short messaging timeout.
    //      Without one it inherits the 6 second default, so a single hung app
    //      can freeze input for 6 s per call.
    //   2. AX round trips happen on `axQueue`, never on main. AppKit work
    //      (`NSRunningApplication`, `NSWorkspace`) stays on main.

    /// AX messaging timeout in seconds, applied to every element created here.
    /// Matches `LayoutService.axMessagingTimeout`.
    private static let axMessagingTimeout: Float = 0.3

    /// Serial queue owning every AX round trip in this file. `.userInteractive`
    /// because it sits directly behind the Option+Tab keystroke.
    private static let axQueue = DispatchQueue(label: "com.hoptab.AppSwitcher.ax", qos: .userInteractive)

    /// Hard cap on how long the one remaining synchronous entry point
    /// (`enumerateWindows(of:)`) may block its caller waiting on `axQueue`.
    /// On expiry it returns an empty list — a missing window picker, not a
    /// frozen keyboard.
    private static let syncWaitDeadline: TimeInterval = 0.4

    /// Create an application AX element with the short messaging timeout applied.
    private static func makeAppElement(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
        return element
    }

    private static func applyMessagingTimeout(_ element: AXUIElement) {
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)
    }

    /// Fetch an app's AX window list, applying the short timeout to the app
    /// element and to every window element it hands back.
    private static func axWindows(of pid: pid_t) -> [AXUIElement] {
        let axApp = makeAppElement(pid)

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return [] }

        for window in windows { applyMessagingTimeout(window) }
        return windows
    }

    /// Run AX work on `axQueue` and wait for it, but never longer than
    /// `deadline`. Returns `fallback` when the queue doesn't finish in time, so
    /// a hung app degrades into "no result" instead of an unbounded main-thread
    /// stall. The queued work still completes; its result is simply dropped.
    private static func awaitOnAXQueue<T>(
        _ fallback: T,
        deadline: TimeInterval,
        _ work: @escaping () -> T
    ) -> T {
        let box = SwitcherValueBox<T>()
        let done = DispatchSemaphore(value: 0)
        axQueue.async {
            box.set(work())
            done.signal()
        }
        guard done.wait(timeout: .now() + deadline) == .success else { return fallback }
        return box.get() ?? fallback
    }

    private static func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    // MARK: - Activation

    /// Activate (bring to front) the app with the given bundle identifier.
    /// Launches the app if it's not running.
    ///
    /// Returns immediately. AppKit work runs on the main thread; the AX steps
    /// (unminimize-if-needed, raise) run on `axQueue`. `completion` — if given —
    /// fires on the main thread once the raise has been attempted.
    static func activate(_ app: PinnedApp, completion: (() -> Void)? = nil) {
        if let running = app.runningApplication {
            activateRunning(running, completion: completion)
        } else if let url = app.applicationURL {
            launchApp(at: url)
            completion?()
        } else {
            completion?()
        }
    }

    private static func activateRunning(_ app: NSRunningApplication, completion: (() -> Void)?) {
        // 1. Unhide first — hidden apps won't come to front otherwise.
        //    AppKit, so it stays on the calling (main) thread.
        if app.isHidden {
            app.unhide()
        }

        let pid = app.processIdentifier

        axQueue.async {
            // 2. If the app has no visible window at all (everything minimized),
            //    restore just the frontmost one so activation has something to
            //    show — don't yank every minimized window out of the Dock.
            unminimizeFrontWindowIfAllMinimized(pid: pid)

            onMain {
                // 3. Use the older, more aggressive activate API.
                //    The macOS 14+ parameterless activate() is weaker and doesn't
                //    always raise windows for apps like Simulator, Terminal, etc.
                app.activate(options: .activateIgnoringOtherApps)

                axQueue.async {
                    // 4. Raise the frontmost window via Accessibility API as a
                    //    fallback. This forces the window to the top of the
                    //    window stack, solving the issue where activate()
                    //    updates the menu bar but leaves the window behind
                    //    other apps.
                    raiseFrontWindow(pid: pid)
                    if let completion {
                        DispatchQueue.main.async(execute: completion)
                    }
                }
            }
        }
    }

    /// Raise only the frontmost window. AX API returns windows front-to-back,
    /// so `windows.first` is the most recently active one.
    /// Must run on `axQueue`.
    private static func raiseFrontWindow(pid: pid_t) {
        guard let frontWindow = axWindows(of: pid).first else { return }
        AXUIElementPerformAction(frontWindow, kAXRaiseAction as CFString)
    }

    /// Minimize the frontmost window of a running app. Returns immediately —
    /// the AX write happens on `axQueue`.
    static func minimizeFirstWindow(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        axQueue.async {
            guard let frontWindow = axWindows(of: pid).first else { return }
            AXUIElementSetAttributeValue(frontWindow, kAXMinimizedAttribute as CFString, true as CFBoolean)
        }
    }

    /// If every window of the app is minimized, unminimize only the frontmost
    /// (most recently used) one. If the app already has at least one visible
    /// window, leave all minimized windows alone.
    /// Must run on `axQueue`.
    private static func unminimizeFrontWindowIfAllMinimized(pid: pid_t) {
        let windows = axWindows(of: pid)
        guard !windows.isEmpty else { return }

        for window in windows {
            var minimized: CFTypeRef?
            let attrResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            let isMin = (attrResult == .success) && (minimized as? Bool == true)
            if !isMin {
                // At least one visible window — nothing to restore.
                return
            }
        }

        // All windows are minimized. AX returns windows front-to-back, so the
        // first one is the most recently used — restore just that one.
        AXUIElementSetAttributeValue(windows[0], kAXMinimizedAttribute as CFString, false as CFBoolean)
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

    /// Look up which Space each window lives on via the private CGS API.
    ///
    /// `CGSCopySpacesForWindows` returns the SET of Spaces the supplied windows
    /// occupy — not one entry per window — so a single batched call can only be
    /// turned into a per-window mapping when that set has exactly one element.
    /// That is the overwhelmingly common case (all of an app's windows live on
    /// one Space), and it replaces the old one-CGS-call-per-window loop with a
    /// single round trip. When an app genuinely straddles Spaces we fall back to
    /// per-window calls, because that is the only way this API can attribute a
    /// Space to an individual window.
    ///
    /// Windows that can't be attributed are simply absent from the result, and
    /// callers treat a missing Space as "unknown" and fail open.
    /// (The old kCGWindowWorkspace key in CGWindowListCopyWindowInfo has been
    /// dead since macOS 10.9 and always returned nil.)
    private static func cgsSpaceIDs(forWindows windowIDs: [CGWindowID]) -> [CGWindowID: Int] {
        guard !windowIDs.isEmpty else { return [:] }
        let conn = CGSMainConnectionID()
        guard conn > 0 else { return [:] }

        let batch = windowIDs.map { NSNumber(value: $0) } as CFArray
        let union = (CGSCopySpacesForWindows(conn, kCGSAllSpacesMask, batch)?
            .takeRetainedValue() as? [Int])?
            .filter { $0 > 0 } ?? []

        guard !union.isEmpty else { return [:] }

        if union.count == 1, let only = union.first {
            var result: [CGWindowID: Int] = [:]
            for id in windowIDs { result[id] = only }
            return result
        }

        var result: [CGWindowID: Int] = [:]
        for id in windowIDs {
            let single = [NSNumber(value: id)] as CFArray
            guard let spaces = CGSCopySpacesForWindows(conn, kCGSAllSpacesMask, single)?
                    .takeRetainedValue() as? [Int],
                  let first = spaces.first(where: { $0 > 0 })
            else { continue }
            result[id] = first
        }
        return result
    }

    /// List windows of a running app via AX API, enriched with stable CGWindowID
    /// and Space info.
    ///
    /// Asynchronous variant: every AX round trip happens on `axQueue`,
    /// `completion` is delivered on the main thread. Prefer this everywhere.
    static func enumerateWindows(of app: NSRunningApplication, completion: @escaping ([WindowInfo]) -> Void) {
        let pid = app.processIdentifier
        axQueue.async {
            let infos = windowInfos(pid: pid)
            DispatchQueue.main.async { completion(infos) }
        }
    }

    /// Synchronous variant, kept because `AppState` consumes the result inline
    /// (`dismissAndActivate`, `expandSelectedAppWindows`, `moveProfileWindows`)
    /// and `AppState` is owned elsewhere.
    ///
    /// It no longer performs AX work on the caller's thread: the reads run on
    /// `axQueue` and the caller waits on a semaphore bounded by
    /// `syncWaitDeadline`. That turns a previously unbounded (6 s per hung AX
    /// call) main-thread stall into a hard 0.4 s ceiling, but the caller is
    /// still blocked for up to that long — migrate to
    /// `enumerateWindows(of:completion:)` to remove the block entirely.
    static func enumerateWindows(of app: NSRunningApplication) -> [WindowInfo] {
        let pid = app.processIdentifier
        return awaitOnAXQueue([], deadline: syncWaitDeadline) { windowInfos(pid: pid) }
    }

    private static let windowInfoAttributes: [String] = [
        kAXTitleAttribute as String,
        kAXRoleAttribute as String,
        kAXMinimizedAttribute as String,
    ]

    /// Title / role / minimized in a SINGLE AX round trip via
    /// `AXUIElementCopyMultipleAttributeValues`, instead of three. That is what
    /// keeps `enumerateWindows(of:)`'s bounded wait comfortable even for an app
    /// with twenty windows. Falls back to individual reads for the rare AX
    /// server that rejects the batched call.
    private static func readWindowInfoState(_ window: AXUIElement) -> (title: String, role: String, minimized: Bool) {
        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            window, windowInfoAttributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef
        )
        if err == .success, let values = valuesRef as? [CFTypeRef], values.count == windowInfoAttributes.count {
            return (
                title: (values[0] as? String) ?? "",
                role: (values[1] as? String) ?? "",
                minimized: (values[2] as? Bool) ?? false
            )
        }

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)
        var minRef: CFTypeRef?
        let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef)
        return (
            title: (titleRef as? String) ?? "",
            role: (roleRef as? String) ?? "",
            minimized: (minResult == .success) && (minRef as? Bool == true)
        )
    }

    /// The actual enumeration. Must run on `axQueue`.
    private static func windowInfos(pid: pid_t) -> [WindowInfo] {
        let windows = axWindows(of: pid)
        guard !windows.isEmpty else { return [] }

        var pending: [(id: CGWindowID, title: String, isMinimized: Bool)] = []
        for window in windows {
            // Get title
            // Title, role and minimized state in ONE AX round trip.
            let state = readWindowInfoState(window)

            // Skip windows with empty titles (utility panels, etc.)
            guard !state.title.isEmpty else { continue }

            // Only include standard windows
            guard state.role == (kAXWindowRole as String) else { continue }

            // Bridge AX window -> stable CGWindowID
            var windowID: CGWindowID = 0
            guard _AXUIElementGetWindow(window, &windowID) == .success, windowID != 0 else { continue }

            pending.append((id: windowID, title: state.title, isMinimized: state.minimized))
        }
        guard !pending.isEmpty else { return [] }

        // One batched Space lookup for every non-minimized window, instead of
        // one CGS round trip per window. Minimized windows live in the Dock,
        // not on a Space, so they're excluded and keep a nil spaceID.
        let liveIDs = pending.filter { !$0.isMinimized }.map(\.id)
        let spaces = cgsSpaceIDs(forWindows: liveIDs)

        return pending.map { entry in
            WindowInfo(
                id: entry.id,
                title: entry.title,
                isMinimized: entry.isMinimized,
                spaceID: entry.isMinimized ? nil : spaces[entry.id]
            )
        }
    }

    /// Filter windows to only those on the current Space.
    /// Minimized windows and windows with unknown Space are included (fail-open).
    /// Pure CGS + value types — safe on any thread.
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
    /// Returns immediately — the AX work runs on `axQueue`.
    // MARK: - Native macOS tabs

    /// One tab of a window that uses the system tab bar (Ghostty, Terminal,
    /// Finder, Xcode…). AppKit exposes the bar as an `AXTabGroup` whose
    /// children are `AXRadioButton`s titled like the tabs.
    struct NativeTab: Equatable {
        let windowID: CGWindowID
        let windowTitle: String
        /// 0-based position in the tab bar.
        let index: Int
        let title: String
        let isSelected: Bool
    }

    /// Tabs of every titled window of `app`, front window first. Empty for
    /// apps that draw their own tab bars (browsers, Electron).
    static func enumerateNativeTabs(of app: NSRunningApplication, completion: @escaping ([NativeTab]) -> Void) {
        let pid = app.processIdentifier
        axQueue.async {
            var out: [NativeTab] = []
            for window in axWindows(of: pid) {
                var wid: CGWindowID = 0
                guard _AXUIElementGetWindow(window, &wid) == .success, wid != 0 else { continue }
                guard let group = findTabGroup(in: window, depth: 0) else { continue }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(group, kAXChildrenAttribute as CFString, &children) == .success,
                      let buttons = children as? [AXUIElement] else { continue }
                let windowTitle = stringAttribute(window, kAXTitleAttribute) ?? ""
                var index = 0
                for button in buttons {
                    guard stringAttribute(button, kAXRoleAttribute) == (kAXRadioButtonRole as String) else { continue }
                    let title = stringAttribute(button, kAXTitleAttribute)
                        ?? stringAttribute(button, kAXDescriptionAttribute) ?? ""
                    var value: CFTypeRef?
                    var selected = false
                    if AXUIElementCopyAttributeValue(button, kAXValueAttribute as CFString, &value) == .success {
                        selected = (value as? Int) == 1 || (value as? Bool) == true
                    }
                    if !title.isEmpty {
                        out.append(NativeTab(windowID: wid, windowTitle: windowTitle, index: index, title: title, isSelected: selected))
                    }
                    index += 1
                }
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// Select a tab found by `enumerateNativeTabs`.
    ///
    /// Order matters: with the system tab bar every tab is its own
    /// `NSWindow`, and raising the window we hold (the one whose tab is
    /// currently selected) re-selects *that* tab. So raise first, press last.
    static func selectNativeTab(of app: NSRunningApplication, windowID: CGWindowID, index: Int) {
        let pid = app.processIdentifier
        axQueue.async {
            for window in axWindows(of: pid) {
                var wid: CGWindowID = 0
                guard _AXUIElementGetWindow(window, &wid) == .success, wid == windowID else { continue }
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                guard let group = findTabGroup(in: window, depth: 0) else { return }
                var children: CFTypeRef?
                guard AXUIElementCopyAttributeValue(group, kAXChildrenAttribute as CFString, &children) == .success,
                      let all = children as? [AXUIElement] else { return }
                let buttons = all.filter { stringAttribute($0, kAXRoleAttribute) == (kAXRadioButtonRole as String) }
                guard buttons.indices.contains(index) else { return }
                AXUIElementPerformAction(buttons[index], kAXPressAction as CFString)
                return
            }
        }
    }

    /// Breadth-limited search for the window's tab group. The system tab bar
    /// sits one or two levels under the window; deeper trees are app-drawn
    /// UI and not worth walking.
    private static func findTabGroup(in element: AXUIElement, depth: Int) -> AXUIElement? {
        guard depth <= 2 else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
              let list = children as? [AXUIElement] else { return nil }
        for child in list where stringAttribute(child, kAXRoleAttribute) == (kAXTabGroupRole as String) {
            return child
        }
        for child in list {
            let role = stringAttribute(child, kAXRoleAttribute)
            guard role == (kAXGroupRole as String) || role == (kAXToolbarRole as String) else { continue }
            if let found = findTabGroup(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private static func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    static func raiseWindow(of app: NSRunningApplication, windowID: CGWindowID) {
        let pid = app.processIdentifier
        axQueue.async {
            for window in axWindows(of: pid) {
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
}

// MARK: - Cross-thread result box

/// Minimal locked box so `awaitOnAXQueue` can hand a value back from `axQueue`
/// without tripping exclusivity checks on a captured `var`.
private final class SwitcherValueBox<T> {
    private let lock = NSLock()
    private var stored: T?

    func set(_ value: T) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    func get() -> T? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

// MARK: - Private AX bridge

/// Extracts the CGWindowID from an AXUIElement window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

// MARK: - Private CGS declarations

/// Connection ID for the current login session.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

/// Returns the Space IDs containing the given windows. Copy function —
/// the caller owns the returned array.
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: UInt32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?

/// Include current, other, and fullscreen Spaces in the lookup.
private let kCGSAllSpacesMask: UInt32 = 0x7

