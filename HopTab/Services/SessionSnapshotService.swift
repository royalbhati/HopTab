import AppKit
import ApplicationServices

enum SessionSnapshotService {

    // MARK: - AX Plumbing
    //
    // HopTab's CGEvent tap run-loop source lives on the MAIN run loop, so a
    // synchronous AX round trip on main stalls the keyboard system-wide. Two
    // rules, obeyed by every entry point below:
    //
    //   1. Every AX element this file creates gets a short messaging timeout.
    //      Without one it inherits the 6 second default, so one hung app can
    //      freeze input for 6 s per call.
    //   2. AX round trips happen on `axQueue`, never on main. `NSScreen`,
    //      `NSWorkspace` and `NSRunningApplication` are main-thread APIs — the
    //      public entry points snapshot what they need (pids, bundle ids,
    //      `LayoutService.ScreenGeometry`) on main and pass value types across.

    /// AX messaging timeout in seconds. Matches `LayoutService`.
    private static let axMessagingTimeout: Float = 0.3

    /// Serial queue owning every AX round trip in this file. Capture and
    /// restore are batch operations that sleep between writes, so they get
    /// their own queue rather than sharing the switcher's.
    private static let axQueue = DispatchQueue(label: "com.hoptab.SessionSnapshot.ax", qos: .userInitiated)

    /// Ceiling on how long the synchronous `captureSnapshot(for:)` may block its
    /// caller. Generous on purpose: a timeout here means returning a stale or
    /// empty snapshot, and `PinnedAppsStore.saveSnapshot` overwrites the stored
    /// snapshot for the current display config, so a premature empty result
    /// would destroy the user's saved layout. With the 0.3 s AX timeout in
    /// place, a realistic profile finishes far inside this.
    private static let syncCaptureDeadline: TimeInterval = 1.5

    /// Ceiling for the cheap one-round-trip readiness probe (`appHasWindows`).
    /// On expiry it reports "not ready", and the caller polls again.
    private static let syncProbeDeadline: TimeInterval = 0.35

    // Retry / verification constants, mirroring `LayoutService.moveWindow`.
    private static let maxRetries = 4
    private static let maxRetryWallTime: TimeInterval = 0.5
    private static let tolerance: CGFloat = 5
    private static let counterOfferTolerance: CGFloat = 24

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
    /// `deadline`. Returns `fallback` when the queue doesn't finish in time.
    /// The queued work still runs to completion; its result is dropped.
    ///
    /// NOTE: nothing dispatched through this may call `DispatchQueue.main.sync`
    /// (that includes `LayoutService.ScreenGeometry.capture()` from off-main) —
    /// the caller holds the main thread while waiting, so it would deadlock the
    /// serial queue permanently. Geometry is always captured before dispatch.
    private static func awaitOnAXQueue<T>(
        _ fallback: T,
        deadline: TimeInterval,
        _ work: @escaping () -> T
    ) -> T {
        let box = SnapshotValueBox<T>()
        let done = DispatchSemaphore(value: 0)
        axQueue.async {
            box.set(work())
            done.signal()
        }
        guard done.wait(timeout: .now() + deadline) == .success else { return fallback }
        return box.get() ?? fallback
    }

    /// Unwrap an `AXValue` out of a multi-attribute result. Entries that
    /// couldn't be fetched come back as `kAXValueAXErrorType` placeholders.
    private static func axUnwrap<T>(_ any: CFTypeRef?, _ type: AXValueType, _ out: inout T) -> Bool {
        guard let any, CFGetTypeID(any) == AXValueGetTypeID() else { return false }
        let value = any as! AXValue
        guard AXValueGetType(value) == type else { return false }
        return AXValueGetValue(value, type, &out)
    }

    // MARK: - Shared Mutable State

    private static let stateLock = NSLock()

    /// CGWindowIDs captured alongside each snapshot, parallel to `snapshot.windows`.
    /// Kept in memory only — CGWindowIDs are stable within a login session, which is
    /// exactly the window ("Save & Close" → "Restore" without relaunch) where they help.
    /// Old persisted snapshots decode unchanged; restores without IDs fall back to
    /// title/frame matching.
    private static var capturedWindowIDs: [UUID: [CGWindowID?]] = [:]

    /// Last snapshot this process captured per profile. Only used as the
    /// non-destructive fallback when a synchronous capture times out.
    private static var lastCaptured: [UUID: SessionSnapshot] = [:]

    private static func windowIDs(forProfile profileId: UUID) -> [CGWindowID?] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return capturedWindowIDs[profileId] ?? []
    }

    private static func recordCapture(_ snapshot: SessionSnapshot, ids: [CGWindowID?]) {
        stateLock.lock()
        capturedWindowIDs[snapshot.profileId] = ids
        lastCaptured[snapshot.profileId] = snapshot
        stateLock.unlock()
    }

    private static func lastKnownCapture(forProfile profileId: UUID) -> SessionSnapshot? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lastCaptured[profileId]
    }

    // MARK: - Main-thread Snapshots
    //
    // `NSRunningApplication` lookups run here and the resulting pids travel to
    // the AX queue as plain values.

    private struct AppTarget {
        let bundleIdentifier: String
        let pid: pid_t
    }

    private static func runningTargets(for profile: Profile) -> [AppTarget] {
        profile.pinnedApps.compactMap { app in
            guard let running = app.runningApplication else { return nil }
            return AppTarget(bundleIdentifier: app.bundleIdentifier, pid: running.processIdentifier)
        }
    }

    private static func runningTargets(forBundles bundles: [String]) -> [AppTarget] {
        bundles.compactMap { bundle in
            guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
            else { return nil }
            return AppTarget(bundleIdentifier: bundle, pid: running.processIdentifier)
        }
    }

    // MARK: - Capture

    /// Snapshot window positions for all running pinned apps in a profile.
    ///
    /// Asynchronous variant: AX work runs on `axQueue`, `completion` is
    /// delivered on the main thread so the caller can mutate published state.
    static func captureSnapshot(for profile: Profile, completion: @escaping (SessionSnapshot) -> Void) {
        let targets = runningTargets(for: profile)
        let displayConfigKey = SessionSnapshot.currentDisplayConfigKey // NSScreen — main thread
        let profileId = profile.id
        axQueue.async {
            let snapshot = captureOnQueue(profileId: profileId, targets: targets, displayConfigKey: displayConfigKey)
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    /// Synchronous variant, kept because `AppState` feeds the result straight
    /// into `store.saveSnapshot(_:)` and `AppState` is owned elsewhere.
    ///
    /// The ~5 AX round trips per window (now batched into one) no longer happen
    /// on the caller's thread — they run on `axQueue` while the caller waits on
    /// a semaphore bounded by `syncCaptureDeadline`. On expiry it returns the
    /// last snapshot this process captured for the profile rather than an empty
    /// one, so a timeout can never wipe a saved layout. Migrate to
    /// `captureSnapshot(for:completion:)` to remove the block entirely.
    static func captureSnapshot(for profile: Profile) -> SessionSnapshot {
        let targets = runningTargets(for: profile)
        let displayConfigKey = SessionSnapshot.currentDisplayConfigKey // NSScreen — main thread
        let profileId = profile.id

        let fallback = lastKnownCapture(forProfile: profileId)
            ?? SessionSnapshot(
                profileId: profileId,
                capturedAt: Date(),
                windows: [],
                displayConfigKey: displayConfigKey
            )

        return awaitOnAXQueue(fallback, deadline: syncCaptureDeadline) {
            captureOnQueue(profileId: profileId, targets: targets, displayConfigKey: displayConfigKey)
        }
    }

    /// Everything one capture needs from a window, fetched in a SINGLE AX round
    /// trip via `AXUIElementCopyMultipleAttributeValues` instead of five.
    private struct CapturedWindowState {
        var role: String
        var title: String
        var frame: CGRect
        var minimized: Bool
    }

    private static let captureAttributes: [String] = [
        kAXRoleAttribute as String,
        kAXTitleAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXMinimizedAttribute as String,
    ]

    private static func readCaptureState(_ window: AXUIElement) -> CapturedWindowState {
        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            window, captureAttributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef
        )
        if err == .success, let values = valuesRef as? [CFTypeRef], values.count == captureAttributes.count {
            var origin = CGPoint.zero
            var size = CGSize.zero
            if axUnwrap(values[2], .cgPoint, &origin), axUnwrap(values[3], .cgSize, &size) {
                return CapturedWindowState(
                    role: (values[0] as? String) ?? "",
                    title: (values[1] as? String) ?? "",
                    frame: CGRect(origin: origin, size: size),
                    minimized: (values[4] as? Bool) ?? false
                )
            }
        }
        return readCaptureStateIndividually(window)
    }

    /// Fallback for apps whose AX server rejects the batched call.
    private static func readCaptureStateIndividually(_ window: AXUIElement) -> CapturedWindowState {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef)

        var titleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleRef)

        var posRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef)
        var position = CGPoint.zero
        _ = axUnwrap(posRef, .cgPoint, &position)

        var sizeRef: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef)
        var size = CGSize.zero
        _ = axUnwrap(sizeRef, .cgSize, &size)

        var minRef: CFTypeRef?
        let minResult = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minRef)

        return CapturedWindowState(
            role: (roleRef as? String) ?? "",
            title: (titleRef as? String) ?? "",
            frame: CGRect(origin: position, size: size),
            minimized: (minResult == .success) && (minRef as? Bool == true)
        )
    }

    /// The actual capture. Must run on `axQueue`.
    private static func captureOnQueue(
        profileId: UUID,
        targets: [AppTarget],
        displayConfigKey: String
    ) -> SessionSnapshot {
        var windows: [WindowSnapshot] = []
        var windowIDs: [CGWindowID?] = []
        var zIndex = 0

        for target in targets {
            for axWindow in axWindows(of: target.pid) {
                let state = readCaptureState(axWindow)

                // Only capture standard windows
                guard state.role == (kAXWindowRole as String) else { continue }

                windows.append(WindowSnapshot(
                    bundleIdentifier: target.bundleIdentifier,
                    windowTitle: state.title,
                    frame: state.frame,
                    isMinimized: state.minimized,
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

        let snapshot = SessionSnapshot(
            profileId: profileId,
            capturedAt: Date(),
            windows: windows,
            displayConfigKey: displayConfigKey
        )
        recordCapture(snapshot, ids: windowIDs)
        return snapshot
    }

    // MARK: - Restore

    /// Restore saved window positions for all running pinned apps in a profile.
    /// Returns immediately — all AX work runs on `axQueue`.
    static func restoreSnapshot(_ snapshot: SessionSnapshot, for profile: Profile) {
        let targets = runningTargets(for: profile)
        let raiseTargets = runningTargets(forBundles: Array(Set(snapshot.windows.map(\.bundleIdentifier))))
        let geometry = LayoutService.ScreenGeometry.capture() // NSScreen — main thread

        axQueue.async {
            for target in targets {
                restoreOnQueue(snapshot: snapshot, target: target, geometry: geometry)
            }
            raiseOnQueue(snapshot: snapshot, targets: raiseTargets)
        }
    }

    /// Final cleanup after a readiness-driven restore: restore frames only for apps
    /// that were never individually restored (so user adjustments made mid-restore
    /// aren't reverted), then re-assert the saved z-order.
    /// Returns immediately — all AX work runs on `axQueue`.
    static func finalizeRestore(_ snapshot: SessionSnapshot, for profile: Profile, skipping restored: Set<String>) {
        let targets = runningTargets(for: profile).filter { !restored.contains($0.bundleIdentifier) }
        let raiseTargets = runningTargets(forBundles: Array(Set(snapshot.windows.map(\.bundleIdentifier))))
        let geometry = LayoutService.ScreenGeometry.capture() // NSScreen — main thread

        axQueue.async {
            for target in targets {
                restoreOnQueue(snapshot: snapshot, target: target, geometry: geometry)
            }
            raiseOnQueue(snapshot: snapshot, targets: raiseTargets)
        }
    }

    /// Whether a running app exposes at least one AX window (i.e. is ready to be
    /// positioned).
    ///
    /// Synchronous, because `AppState.restoreSession`'s readiness poll branches
    /// on the result inline. It is a single AX round trip on `axQueue` bounded
    /// by `syncProbeDeadline`; on expiry it reports "not ready" and the caller's
    /// 0.5 s poll simply asks again.
    static func appHasWindows(_ running: NSRunningApplication) -> Bool {
        let pid = running.processIdentifier
        return awaitOnAXQueue(false, deadline: syncProbeDeadline) {
            !axWindows(of: pid).isEmpty
        }
    }

    /// Restore saved frames for a single app's windows.
    /// Matching order: CGWindowID (same login session) → exact title →
    /// frame proximity in saved-index order.
    /// Returns immediately — all AX work runs on `axQueue`.
    static func restoreWindows(from snapshot: SessionSnapshot, bundleIdentifier: String) {
        guard let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        else { return }
        let target = AppTarget(bundleIdentifier: bundleIdentifier, pid: running.processIdentifier)
        let geometry = LayoutService.ScreenGeometry.capture() // NSScreen — main thread

        axQueue.async {
            restoreOnQueue(snapshot: snapshot, target: target, geometry: geometry)
        }
    }

    /// Live window identity/state, read in one AX round trip.
    private struct LiveWindow {
        let element: AXUIElement
        let windowID: CGWindowID?
        let title: String
        let frame: CGRect
        let minimized: Bool
    }

    private static let liveAttributes: [String] = [
        kAXTitleAttribute as String,
        kAXPositionAttribute as String,
        kAXSizeAttribute as String,
        kAXMinimizedAttribute as String,
    ]

    private static func readLiveWindow(_ window: AXUIElement) -> LiveWindow {
        var title = ""
        var frame = CGRect.zero
        var minimized = false

        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            window, liveAttributes as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef
        )
        var resolved = false
        if err == .success, let values = valuesRef as? [CFTypeRef], values.count == liveAttributes.count {
            var origin = CGPoint.zero
            var size = CGSize.zero
            if axUnwrap(values[1], .cgPoint, &origin), axUnwrap(values[2], .cgSize, &size) {
                title = (values[0] as? String) ?? ""
                frame = CGRect(origin: origin, size: size)
                minimized = (values[3] as? Bool) ?? false
                resolved = true
            }
        }
        if !resolved {
            let state = readCaptureStateIndividually(window)
            title = state.title
            frame = state.frame
            minimized = state.minimized
        }

        var windowID: CGWindowID = 0
        let hasID = _AXUIElementGetWindow(window, &windowID) == .success && windowID != 0

        return LiveWindow(
            element: window,
            windowID: hasID ? windowID : nil,
            title: title,
            frame: frame,
            minimized: minimized
        )
    }

    /// The actual per-app restore. Must run on `axQueue`.
    private static func restoreOnQueue(
        snapshot: SessionSnapshot,
        target: AppTarget,
        geometry: LayoutService.ScreenGeometry
    ) {
        let capturedIDs = windowIDs(forProfile: snapshot.profileId)
        var saved: [(ws: WindowSnapshot, windowID: CGWindowID?)] = []
        for (index, ws) in snapshot.windows.enumerated() where ws.bundleIdentifier == target.bundleIdentifier {
            saved.append((ws: ws, windowID: index < capturedIDs.count ? capturedIDs[index] : nil))
        }
        guard !saved.isEmpty else { return }

        // Enumerate live windows once, with their identity/title/frame/minimized
        let live = axWindows(of: target.pid).map(readLiveWindow)
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
            let savedFrame = saved[si].ws.frame
            let li = live.indices
                .filter { !claimed[$0] }
                .min { frameDistance(live[$0].frame, savedFrame) < frameDistance(live[$1].frame, savedFrame) }
            guard let li else { break }
            matchedLiveIndex[si] = li
            claimed[li] = true
        }

        for (si, s) in saved.enumerated() {
            guard let li = matchedLiveIndex[si] else { continue }
            let axWindow = live[li].element
            var currentlyMinimized = live[li].minimized

            // A minimized window can't be positioned. Unminimize first when the
            // snapshot says this window should end up visible.
            if currentlyMinimized && !s.ws.isMinimized {
                AXUIElementSetAttributeValue(axWindow, kAXMinimizedAttribute as CFString, false as CFBoolean)
                usleep(200_000) // un-minimize animation; background queue only
                currentlyMinimized = false
            }

            // Write the frame through the hardened path (retry + verify +
            // EnhancedUI discipline). Skipped only when the window both was and
            // stays minimized — there is nothing on screen to place.
            if !(currentlyMinimized && s.ws.isMinimized) {
                applyWindowFrame(
                    axWindow,
                    to: s.ws.frame,
                    clampTo: clampFrame(for: s.ws.frame, in: geometry)
                )
            }

            // Restore minimized state
            if currentlyMinimized != s.ws.isMinimized {
                AXUIElementSetAttributeValue(
                    axWindow,
                    kAXMinimizedAttribute as CFString,
                    s.ws.isMinimized as CFBoolean
                )
            }
        }
    }

    private static func frameDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.origin.x - b.origin.x) + abs(a.origin.y - b.origin.y)
            + abs(a.width - b.width) + abs(a.height - b.height)
    }

    // MARK: - Hardened Frame Application
    //
    // Session restore used to write position then size ONCE, with no retry, no
    // verification, no minimum-size handling and no AXEnhancedUserInterface
    // handling — the exact failure mode `LayoutService.moveWindow` exists to
    // solve, which is why Chrome, Terminal and Electron windows landed short.
    //
    // `LayoutService.moveWindow` is `private`, and the only public frame writer
    // (`LayoutService.snapWindow(_:pid:to:on:)`) takes a `SnapDirection`, not an
    // arbitrary rect — restore needs arbitrary saved rects. So the same
    // discipline is mirrored here, using the same constants.

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
    private static func writeFrame(_ window: AXUIElement, _ frame: CGRect, sizeFirst: Bool) {
        if sizeFirst {
            setSize(window, frame.size)
            setPosition(window, frame.origin)
            setSize(window, frame.size)
        } else {
            setPosition(window, frame.origin)
            setSize(window, frame.size)
            setPosition(window, frame.origin)
        }
    }

    /// Read the current frame of a window — one round trip (position + size).
    private static func readFrame(_ window: AXUIElement) -> CGRect {
        var valuesRef: CFArray?
        let attrs = [kAXPositionAttribute as String, kAXSizeAttribute as String]
        let err = AXUIElementCopyMultipleAttributeValues(
            window, attrs as CFArray, AXCopyMultipleAttributeOptions(rawValue: 0), &valuesRef
        )
        var origin = CGPoint.zero
        var size = CGSize.zero
        if err == .success, let values = valuesRef as? [CFTypeRef], values.count == 2,
           axUnwrap(values[0], .cgPoint, &origin), axUnwrap(values[1], .cgSize, &size) {
            return CGRect(origin: origin, size: size)
        }

        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return .zero }
        origin = .zero
        size = .zero
        _ = axUnwrap(posRef, .cgPoint, &origin)
        _ = axUnwrap(sizeRef, .cgSize, &size)
        return CGRect(origin: origin, size: size)
    }

    private static func frameMatches(_ actual: CGRect, _ target: CGRect, tolerance tol: CGFloat) -> Bool {
        abs(actual.origin.x - target.origin.x) <= tol
            && abs(actual.origin.y - target.origin.y) <= tol
            && abs(actual.width - target.width) <= tol
            && abs(actual.height - target.height) <= tol
    }

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

    /// Full Quartz frame of the display that best contains `frame`, used ONLY to
    /// pull a window back on screen when an app refuses to shrink to the saved
    /// size. Deliberately the full frame rather than `quartzVisible`: a snapshot
    /// may legitimately hold a window tucked under the menu bar, and clamping to
    /// the visible frame would nudge it on every single restore.
    private static func clampFrame(for frame: CGRect, in geometry: LayoutService.ScreenGeometry) -> CGRect? {
        guard !geometry.displays.isEmpty else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        if let hit = geometry.displays.first(where: { $0.quartzFrame.contains(center) }) {
            return hit.quartzFrame
        }
        var best: CGRect?
        var bestArea: CGFloat = 0
        for display in geometry.displays {
            let overlap = display.quartzFrame.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = display.quartzFrame
            }
        }
        return best
    }

    /// Move a window to `target` with retry and verification. Returns true when
    /// the window ended up at (or acceptably near) the target.
    /// Must run on `axQueue` — the inter-attempt waits would otherwise block
    /// the main thread (and, through it, the CGEvent tap).
    ///
    /// `clampTo` is applied only to the ACTUAL resulting frame, never to the
    /// requested one: a saved frame is a frame that really existed, so it is
    /// taken at face value, and the clamp exists purely to rescue windows whose
    /// app enforces a minimum size and would otherwise hang off the display.
    @discardableResult
    private static func applyWindowFrame(
        _ window: AXUIElement,
        to target: CGRect,
        clampTo screen: CGRect?
    ) -> Bool {
        dispatchPrecondition(condition: .onQueue(axQueue))
        applyMessagingTimeout(window)

        guard !target.isEmpty else { return false }

        let desired = target
        let deadline = Date().addingTimeInterval(maxRetryWallTime)

        var probed = false
        var enhancedApp: AXUIElement?
        var enhancedPrior = false
        defer {
            // Restore the CAPTURED prior value, never a hard-coded `true`.
            if let app = enhancedApp { setEnhancedUI(app, enhancedPrior) }
        }

        var actual = CGRect.zero
        var accepted = false

        for attempt in 0..<maxRetries {
            writeFrame(window, desired, sizeFirst: attempt >= 2)

            actual = readFrame(window)
            if frameMatches(actual, desired, tolerance: tolerance) {
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
            // window that can never reach the target stops early instead of
            // burning the full budget.
            let backoff = useconds_t((attempt + 1) * 80_000) // 80ms, 160ms, 240ms
            guard attempt < maxRetries - 1,
                  Date().addingTimeInterval(Double(backoff) / 1_000_000) < deadline
            else { break }

            if !probed {
                probed = true

                // Fixed-size windows can't be resized — set position once and
                // stop (verification against size would fail forever).
                var sizeSettable: DarwinBoolean = true
                if AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable) == .success,
                   !sizeSettable.boolValue {
                    setPosition(window, desired.origin)
                    actual = readFrame(window)
                    break
                }

                // AXEnhancedUserInterface (set by real assistive tech, or left
                // on by another tool) makes AppKit and Chromium apps animate or
                // mis-apply AX frame changes, so restored windows land short.
                // Turn it off for the remaining attempts and restore the app's
                // prior value on exit.
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

            // Safe here: this function only ever runs on `axQueue`.
            usleep(backoff)
        }

        // Re-anchor against the REAL resulting frame. A window that refused to
        // shrink below its minimum width would otherwise hang off the display.
        if let screen, !actual.isEmpty {
            let anchored = reAnchor(actual, within: screen)
            if abs(anchored.origin.x - actual.origin.x) > 1 || abs(anchored.origin.y - actual.origin.y) > 1 {
                setPosition(window, anchored.origin)
                actual = CGRect(origin: anchored.origin, size: actual.size)
            }
        }

        if accepted { return true }
        return !actual.isEmpty && frameMatches(actual, desired, tolerance: counterOfferTolerance)
    }

    // MARK: - Z-order

    /// Restore z-ordering: raise windows from back to front.
    ///
    /// Linear in the number of windows. The old version re-queried each app's
    /// entire AX window list — and re-read every window's title — once per saved
    /// window, which is O(W²) AX round trips. Now each app's window list is read
    /// exactly once and indexed by CGWindowID and title.
    /// Must run on `axQueue`.
    private static func raiseOnQueue(snapshot: SessionSnapshot, targets: [AppTarget]) {
        guard !targets.isEmpty else { return }

        var byID: [String: [CGWindowID: AXUIElement]] = [:]
        var byTitle: [String: [String: AXUIElement]] = [:]

        for target in targets {
            var ids: [CGWindowID: AXUIElement] = [:]
            var titles: [String: AXUIElement] = [:]
            for axWindow in axWindows(of: target.pid) {
                var windowID: CGWindowID = 0
                if _AXUIElementGetWindow(axWindow, &windowID) == .success, windowID != 0 {
                    ids[windowID] = axWindow
                }
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                if let title = titleRef as? String, titles[title] == nil {
                    titles[title] = axWindow
                }
            }
            byID[target.bundleIdentifier] = ids
            byTitle[target.bundleIdentifier] = titles
        }

        let capturedIDs = windowIDs(forProfile: snapshot.profileId)
        let sortedWindows = snapshot.windows.enumerated().sorted { $0.element.zIndex > $1.element.zIndex }
        for (index, ws) in sortedWindows {
            let savedID = index < capturedIDs.count ? capturedIDs[index] : nil
            let match = savedID.flatMap { byID[ws.bundleIdentifier]?[$0] }
                ?? byTitle[ws.bundleIdentifier]?[ws.windowTitle]
            if let match {
                AXUIElementPerformAction(match, kAXRaiseAction as CFString)
            }
        }
    }

    // MARK: - Hide / Unhide
    //
    // Pure AppKit (`NSRunningApplication`) — main thread, no AX, nothing to move.

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

// MARK: - Cross-thread result box

/// Minimal locked box so `awaitOnAXQueue` can hand a value back from `axQueue`.
private final class SnapshotValueBox<T> {
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

/// Extracts the CGWindowID from an AXUIElement window.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError
