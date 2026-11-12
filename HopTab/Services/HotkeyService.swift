import Cocoa
import Carbon.HIToolbox
import ApplicationServices

final class HotkeyService {
    // App Switcher Callbacks
    /// Pinned-only switcher (the configurable preset, ⌥Tab by default).
    var onSwitcherActivated: (() -> Void)?
    /// All-apps switcher (⌘Tab when "Replace ⌘Tab" is on). Shares every
    /// other switcher callback — only the list it opens with differs.
    var onAllAppsSwitcherActivated: (() -> Void)?
    /// ⌥K command palette. A plain press-and-release hotkey: no modifier
    /// tracking, no cycling. Toggles the palette.
    var onCommandPaletteActivated: (() -> Void)?
    var onCycleForward: (() -> Void)?
    var onCycleBackward: (() -> Void)?
    var onSwitcherDismissed: (() -> Void)?
    var onSwitcherCancelled: (() -> Void)?
    var onTapFailed: (() -> Void)?

    // Profile Switcher Callbacks
    var onProfileSwitcherActivated: (() -> Void)?
    var onProfileCycleForward: (() -> Void)?
    var onProfileCycleBackward: (() -> Void)?
    var onProfileSwitcherDismissed: (() -> Void)?
    var onProfileSwitcherCancelled: (() -> Void)?

    // Per-Profile Hotkey Callbacks
    var onProfileHotkeyActivated: ((UUID) -> Void)?
    var onProfileHotkeyCycleForward: ((UUID) -> Void)?
    var onProfileHotkeyCycleBackward: ((UUID) -> Void)?
    var onProfileHotkeyDismissed: ((UUID) -> Void)?

    // App Action Callbacks (Cmd+Q/H/M while switcher is active)
    var onQuitHighlighted: (() -> Void)?
    var onHideHighlighted: (() -> Void)?
    var onMinimizeHighlighted: (() -> Void)?

    // Window Picker Callbacks
    var onWindowPickerNavigateUp: (() -> Void)?
    var onWindowPickerNavigateDown: (() -> Void)?
    var onWindowPickerSelect: (() -> Void)?
    var onWindowPickerCancel: (() -> Void)?

    // Expand highlighted app into its windows (Space while switcher active)
    var onExpandWindows: (() -> Void)?

    // Profile membership from inside the switcher.
    // 1–9 toggles the highlighted app in profile N; P toggles it in the
    // active profile; Delete removes it from the active profile.
    var onToggleHighlightedInProfileSlot: ((Int) -> Void)?
    var onToggleHighlightedInActiveProfile: (() -> Void)?
    var onUnpinHighlighted: (() -> Void)?
    /// N: create a new workspace containing the highlighted app.
    var onCreateWorkspaceWithHighlighted: (() -> Void)?

    // Snap Callbacks (arrow keys while switcher active)
    var onSnapLeft: (() -> Void)?
    var onSnapRight: (() -> Void)?
    var onSnapFull: (() -> Void)?
    var onSnapBottom: (() -> Void)?

    // Global Snap Shortcuts (work without switcher)
    var snapShortcuts: [(modifiers: CGEventFlags, keyCode: Int64, direction: SnapDirection)] = []
    var onGlobalSnap: ((SnapDirection) -> Void)?

    // Mouse events for drag-to-snap. Delivered from a separate listen-only tap,
    // so a handler here can observe but never modify or swallow the event.
    var onMouseEvent: ((CGEventType, CGEvent) -> Void)?

    /// Fired on the main queue when macOS secure event input turns on or off.
    /// While it is on (Terminal's Secure Keyboard Entry, a focused password
    /// field) the tap receives no key events at all, so every global shortcut
    /// silently stops working. UI can subscribe to explain that.
    var onSecureInputChange: ((Bool) -> Void)?

    /// When false, no mouse tap is created at all, eliminating
    /// 60-120 Hz main-thread wake-ups from system mouse drags.
    var includeMouseEvents: Bool = false {
        didSet {
            guard oldValue != includeMouseEvents, isRunning else { return }
            // Only the mouse tap changes — never tear down the keyboard tap
            // (that would reset switcher state mid-gesture).
            if includeMouseEvents { startMouseTap() } else { stopMouseTap() }
        }
    }

    // App Switcher shortcut (configurable)
    private(set) var modifierFlag: CGEventFlags = .maskAlternate
    private(set) var triggerKeyCode: Int64 = Int64(kVK_Tab)

    /// Second app-switcher trigger showing every running app. nil = off.
    private(set) var allAppsTrigger: (modifierFlag: CGEventFlags, keyCode: Int64)?

    /// Command palette trigger, or nil when disabled.
    private(set) var commandPaletteTrigger: (modifierFlag: CGEventFlags, keyCode: Int64)?

    /// Which modifier opened the switcher that is currently active, so
    /// release detection watches the right key whichever trigger fired.
    private var activeSwitcherModifier: CGEventFlags?

    // Profile Switcher shortcut (configurable)
    private(set) var profileModifierFlag: CGEventFlags = .maskAlternate
    private(set) var profileTriggerKeyCode: Int64 = Int64(kVK_ANSI_Grave)

    // State
    private(set) var isModifierHeld = false
    private(set) var isSwitcherActive = false
    private(set) var isProfileModifierHeld = false
    private(set) var isProfileSwitcherActive = false

    // Window picker state
    private(set) var isWindowPickerActive = false

    // Per-profile hotkey state
    private(set) var profileHotkeys: [(modifierFlag: CGEventFlags, keyCode: Int64, profileId: UUID)] = []
    private(set) var activeProfileHotkeyId: UUID?
    private(set) var profileHotkeyModifierHeld = false
    private(set) var profileHotkeyModifier: CGEventFlags?

    /// True while some process has macOS secure event input enabled.
    /// Updated by `verifyTapAlive()` and on tap start.
    private(set) var isSecureInputActive = false

    /// Cached `AXIsProcessTrusted()`. Calling it from the tap callback is an
    /// XPC round trip on the input path, so it is cached here and refreshed
    /// by `refreshTrust()`, `verifyTapAlive()` and tap start/stop.
    private var isProcessTrusted = AXIsProcessTrusted()

    /// Key codes whose keyDown we swallowed, so the matching keyUp can be
    /// swallowed too. Needed because handlers now run asynchronously: the
    /// state they set (e.g. window-picker mode) may not be visible yet when
    /// the keyUp arrives, and the focused app must never see a lone keyUp.
    private var swallowedKeyDowns = Set<Int64>()

    // Event tap — keyboard. Active (.defaultTap) because it must swallow keys.
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // Event tap — mouse (drag-to-snap observation only). Listen-only, so
    // HopTab's main thread is not in the mouse event delivery critical path.
    private var mouseEventTap: CFMachPort?
    private var mouseRunLoopSource: CFRunLoopSource?

    func configure(preset: ShortcutPreset) {
        let wasRunning = eventTap != nil
        if wasRunning { stop() }
        modifierFlag = preset.modifierFlag
        triggerKeyCode = preset.keyCode
        if wasRunning { start() }
    }

    func configureAppShortcut(modifierFlag: CGEventFlags, keyCode: Int64) {
        let wasRunning = eventTap != nil
        if wasRunning { stop() }
        self.modifierFlag = modifierFlag
        self.triggerKeyCode = keyCode
        if wasRunning { start() }
    }

    func configureAllAppsSwitcher(_ trigger: (modifierFlag: CGEventFlags, keyCode: Int64)?) {
        let wasRunning = eventTap != nil
        if wasRunning { stop() }
        allAppsTrigger = trigger
        if wasRunning { start() }
    }

    func configureCommandPalette(_ trigger: (modifierFlag: CGEventFlags, keyCode: Int64)?) {
        commandPaletteTrigger = trigger
    }

    func configureProfileShortcut(modifierFlag: CGEventFlags, keyCode: Int64) {
        let wasRunning = eventTap != nil
        if wasRunning { stop() }
        profileModifierFlag = modifierFlag
        profileTriggerKeyCode = keyCode
        if wasRunning { start() }
    }

    /// The global snap binding this key event matches, if any. See the comment
    /// in `handleEvent` for why fn is ignored on arrow / nav / function keys.
    private func matchedGlobalSnap(keyCode: Int64, flags: CGEventFlags) -> (modifiers: CGEventFlags, keyCode: Int64, direction: SnapDirection)? {
        var snapMods = CGEventFlags([.maskControl, .maskAlternate, .maskCommand, .maskShift])
        if !KeyCodeMapping.keysImplyingFunctionModifier.contains(Int(keyCode)) {
            snapMods.insert(.maskSecondaryFn)
        }
        let eventMods = flags.intersection(snapMods)
        return snapShortcuts.first { snap in
            snap.modifiers.intersection(snapMods) == eventMods && snap.keyCode == keyCode
        }
    }

    func configureSnapShortcuts(_ config: SnapShortcutConfig) {
        snapShortcuts = config.bindings.map { (direction, shortcut) in
            // `matchingFlags` adds the fn bit when the user actually recorded
            // fn; `modifierFlags` stays ⌃⌥⇧⌘-only for storage compatibility.
            (modifiers: shortcut.matchingFlags, keyCode: shortcut.keyCode, direction: direction)
        }
    }

    func configureProfileHotkeys(_ hotkeys: [(UUID, CustomShortcut)]) {
        profileHotkeys = hotkeys.map { (id, shortcut) in
            (modifierFlag: shortcut.modifierFlags, keyCode: shortcut.keyCode, profileId: id)
        }
        // Only reset active state if the active profile's hotkey was removed;
        // otherwise an in-flight interaction (modifier still held) would break.
        if let activeId = activeProfileHotkeyId,
           !profileHotkeys.contains(where: { $0.profileId == activeId }) {
            activeProfileHotkeyId = nil
            profileHotkeyModifierHeld = false
            profileHotkeyModifier = nil
        }
    }

    func start() {
        guard eventTap == nil else { return }

        // Keyboard only — mouse events get their own listen-only tap below.
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[HotkeyService] Failed to create event tap — Accessibility not granted?")
            DispatchQueue.main.async { [weak self] in
                self?.onTapFailed?()
            }
            return
        }

        eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        refreshTrust()
        updateSecureInputState()

        if includeMouseEvents { startMouseTap() }

        NSLog("[HotkeyService] Event tap started — app modifier=0x%llx key=%lld, profile modifier=0x%llx key=%lld",
              modifierFlag.rawValue, triggerKeyCode,
              profileModifierFlag.rawValue, profileTriggerKeyCode)
    }

    /// Create the separate listen-only mouse tap used for drag-to-snap.
    /// Listen-only cannot modify or swallow events — `onMouseEvent` only
    /// observes drags (see `DragSnapService.handleMouseEvent`, which returns
    /// Void), so this keeps us out of the mouse delivery critical section.
    private func startMouseTap() {
        guard mouseEventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: mouseTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            NSLog("[HotkeyService] Failed to create mouse event tap — drag-to-snap disabled")
            return
        }

        mouseEventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        mouseRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        NSLog("[HotkeyService] Mouse event tap started (listen-only)")
    }

    private func stopMouseTap() {
        if let tap = mouseEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = mouseRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        mouseEventTap = nil
        mouseRunLoopSource = nil
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        stopMouseTap()
        swallowedKeyDowns.removeAll()
        isModifierHeld = false
        isSwitcherActive = false
        activeSwitcherModifier = nil
        isProfileModifierHeld = false
        isProfileSwitcherActive = false
        isWindowPickerActive = false
        activeProfileHotkeyId = nil
        profileHotkeyModifierHeld = false
        profileHotkeyModifier = nil
    }

    deinit {
        stop()
    }

    var isRunning: Bool { eventTap != nil }

    // MARK: - Watchdog

    /// Cheap liveness check for both taps. macOS disables a tap on timeout or
    /// on certain user input and never tells us again, so shortcuts die
    /// silently. Call this periodically (AppState's existing 30 s
    /// `meetingHUDTimer` is a good place) — it re-enables anything that was
    /// disabled and refreshes the cached Accessibility-trust and
    /// secure-input state.
    func verifyTapAlive() {
        refreshTrust()
        updateSecureInputState()

        if let tap = eventTap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("[HotkeyService] Watchdog: keyboard tap was disabled — re-enabled")
        }
        if let tap = mouseEventTap, !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            NSLog("[HotkeyService] Watchdog: mouse tap was disabled — re-enabled")
        }
    }

    /// Refresh the cached `AXIsProcessTrusted()` value. Call after the user
    /// may have changed the Accessibility permission (it is never read from
    /// the event tap callback itself — that would be an XPC round trip on
    /// the input path).
    func refreshTrust() {
        isProcessTrusted = AXIsProcessTrusted()
    }

    private func updateSecureInputState() {
        let active = IsSecureEventInputEnabled()
        guard active != isSecureInputActive else { return }
        isSecureInputActive = active
        NSLog("[HotkeyService] Secure event input %@",
              active ? "ENABLED — global shortcuts will not fire" : "disabled")
        enqueue(onSecureInputChange, with: active)
    }

    func enterWindowPickerMode() {
        isWindowPickerActive = true
        // Leaving the app switcher — prevent a trailing onSwitcherDismissed
        // from firing when the user releases the modifier over the picker.
        isSwitcherActive = false
    }

    func exitWindowPickerMode() {
        isWindowPickerActive = false
    }

    // MARK: - Event Processing

    /// Run a callback on the next main run-loop pass. Used for handlers that
    /// perform AX / window-management work so the CGEvent tap callback only
    /// classifies the event and returns immediately.
    /// Zero-based profile slot for the digit row 1–9 (main row and keypad).
    private static func profileSlot(forKeyCode keyCode: Int64) -> Int? {
        switch keyCode {
        case Int64(kVK_ANSI_1), Int64(kVK_ANSI_Keypad1): return 0
        case Int64(kVK_ANSI_2), Int64(kVK_ANSI_Keypad2): return 1
        case Int64(kVK_ANSI_3), Int64(kVK_ANSI_Keypad3): return 2
        case Int64(kVK_ANSI_4), Int64(kVK_ANSI_Keypad4): return 3
        case Int64(kVK_ANSI_5), Int64(kVK_ANSI_Keypad5): return 4
        case Int64(kVK_ANSI_6), Int64(kVK_ANSI_Keypad6): return 5
        case Int64(kVK_ANSI_7), Int64(kVK_ANSI_Keypad7): return 6
        case Int64(kVK_ANSI_8), Int64(kVK_ANSI_Keypad8): return 7
        case Int64(kVK_ANSI_9), Int64(kVK_ANSI_Keypad9): return 8
        default: return nil
        }
    }

    private func enqueue(_ callback: (() -> Void)?) {
        guard let callback else { return }
        DispatchQueue.main.async { callback() }
    }

    /// Same as `enqueue(_:)` for callbacks that take one argument.
    private func enqueue<T>(_ callback: ((T) -> Void)?, with argument: T) {
        guard let callback else { return }
        DispatchQueue.main.async { callback(argument) }
    }

    /// Mouse events from the separate listen-only tap. Called on the main
    /// thread; the handler only records positions and schedules AX work on
    /// its own queue, and a listen-only tap is not in the delivery path, so
    /// no copy + dispatch hop is needed here.
    fileprivate func handleMouseTapEvent(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = mouseEventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                NSLog("[HotkeyService] Re-enabled mouse tap (disabled by %@)",
                      type == .tapDisabledByTimeout ? "timeout" : "user input")
            }
            return
        }
        switch type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp:
            onMouseEvent?(type, event)
        default:
            break
        }
    }

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> CGEvent? {
        // Re-enable the tap if macOS disabled it — by timeout (we were too slow
        // on some event) or by user input. Either way it stays dead until
        // re-enabled, which is a silent loss of every shortcut.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                if isWindowPickerActive {
                    isWindowPickerActive = false
                    enqueue(onWindowPickerCancel)
                }
                if isSwitcherActive {
                    isSwitcherActive = false
                    enqueue(onSwitcherCancelled)
                }
                if isProfileSwitcherActive {
                    isProfileSwitcherActive = false
                    enqueue(onProfileSwitcherCancelled)
                }
                if let profileId = activeProfileHotkeyId {
                    activeProfileHotkeyId = nil
                    profileHotkeyModifierHeld = false
                    profileHotkeyModifier = nil
                    enqueue(onProfileHotkeyDismissed, with: profileId)
                }
                isModifierHeld = false
                activeSwitcherModifier = nil
                isProfileModifierHeld = false
                swallowedKeyDowns.removeAll()

                CGEvent.tapEnable(tap: tap, enable: true)
                NSLog("[HotkeyService] Re-enabled event tap after %@ — reset all state",
                      type == .tapDisabledByTimeout ? "timeout" : "user-input disable")
            }
            return event
        }

        // Keys HopTab posted itself (custom commands) are for the target app,
        // never for us.
        if event.getIntegerValueField(.eventSourceUserData) == CustomCommandRunner.syntheticUserData {
            return event
        }

        // Let events through when HopTab's own windows are focused (e.g. settings)
        // so text fields, TextEditors, etc. work normally.
        // Skip this bypass when a switcher is actively being used.
        //
        // Global snap shortcuts are the one exception: ⌃⌥←, ⌃⌥Z and friends are
        // never text input, and people press them with the menu popover or
        // Settings in front and expect the window to move (the snap then
        // targets HopTab's own frontmost window, which is what Rectangle does).
        if NSApp.isActive
            && !isSwitcherActive && !isProfileSwitcherActive
            && !isWindowPickerActive && activeProfileHotkeyId == nil
            && !(type == .keyDown && matchedGlobalSnap(keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags) != nil) {
            return event
        }

        let flags = event.flags

        // MARK: Flags Changed (modifier key up/down)
        if type == .flagsChanged {
            // Whichever trigger opened the switcher, releasing ITS modifier
            // dismisses it. Dismissal activates an app (AX work) — enqueue;
            // the flag is already cleared so the swallow never waits on it.
            if isSwitcherActive, let active = activeSwitcherModifier, !flags.contains(active) {
                isSwitcherActive = false
                activeSwitcherModifier = nil
                enqueue(onSwitcherDismissed)
                return nil
            }

            // Pinned-switcher modifier tracking (pre-activation state).
            let appModDown = flags.contains(modifierFlag)
            if appModDown && !isModifierHeld {
                isModifierHeld = true
            } else if !appModDown && isModifierHeld {
                isModifierHeld = false
            }

            // Profile switcher modifier tracking
            let profileModDown = flags.contains(profileModifierFlag)
            if profileModDown && !isProfileModifierHeld {
                isProfileModifierHeld = true
            } else if !profileModDown && isProfileModifierHeld {
                isProfileModifierHeld = false
                if isProfileSwitcherActive {
                    isProfileSwitcherActive = false
                    enqueue(onProfileSwitcherDismissed)
                    return nil
                }
            }

            // Per-profile hotkey modifier release tracking
            if let mod = profileHotkeyModifier, let profileId = activeProfileHotkeyId {
                if !flags.contains(mod) {
                    activeProfileHotkeyId = nil
                    profileHotkeyModifierHeld = false
                    profileHotkeyModifier = nil
                    enqueue(onProfileHotkeyDismissed, with: profileId)
                    return nil
                }
            }

            return event
        }


        if type == .keyDown || type == .keyUp {
            if isSwitcherActive, let active = activeSwitcherModifier, !flags.contains(active) {
                isSwitcherActive = false
                activeSwitcherModifier = nil
                enqueue(onSwitcherDismissed)
            }
            let actualAppMod = flags.contains(modifierFlag)
            if isModifierHeld && !actualAppMod {
                isModifierHeld = false
            } else if !isModifierHeld && actualAppMod {
                isModifierHeld = true
            }

            let actualProfileMod = flags.contains(profileModifierFlag)
            if isProfileModifierHeld && !actualProfileMod {
                isProfileModifierHeld = false
                if isProfileSwitcherActive {
                    isProfileSwitcherActive = false
                    enqueue(onProfileSwitcherDismissed)
                }
            } else if !isProfileModifierHeld && actualProfileMod {
                isProfileModifierHeld = true
            }

            // Sync per-profile hotkey modifier on key events
            if let mod = profileHotkeyModifier, let profileId = activeProfileHotkeyId {
                if !flags.contains(mod) {
                    activeProfileHotkeyId = nil
                    profileHotkeyModifierHeld = false
                    profileHotkeyModifier = nil
                    enqueue(onProfileHotkeyDismissed, with: profileId)
                }
            }
        }

        // MARK: Key Down
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            // Hardware key repeat. Window actions must fire once per physical
            // press: a held snap shortcut would otherwise queue ~30 window
            // moves a second onto the serial AX queue and keep moving the
            // window for seconds after release.
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

            /// Swallow this keyDown, remembering the key code so its keyUp is
            /// swallowed too — the focused app must never see a lone keyUp for
            /// a keyDown we consumed (handlers now run asynchronously, so the
            /// mode flags they set may not be visible yet at keyUp time).
            func swallow() -> CGEvent? {
                if swallowedKeyDowns.count > 32 { swallowedKeyDowns.removeAll() }
                swallowedKeyDowns.insert(keyCode)
                return nil
            }

            // Window picker mode — intercept all keys, only allow Up/Down/Enter/Escape
            if isWindowPickerActive {
                switch keyCode {
                case Int64(kVK_UpArrow):
                    // List navigation — key repeat is wanted here.
                    enqueue(onWindowPickerNavigateUp)
                case Int64(kVK_DownArrow):
                    enqueue(onWindowPickerNavigateDown)
                case Int64(kVK_Return), Int64(kVK_ANSI_KeypadEnter):
                    // Raises a window (AX work) — once per press.
                    if !isRepeat { enqueue(onWindowPickerSelect) }
                case Int64(kVK_Escape):
                    if !isRepeat { enqueue(onWindowPickerCancel) }
                default:
                    break // swallow all other keys
                }
                return swallow()
            }

            // Space on a highlighted app → drill into its windows.
            // Enumerates the app's windows over AX — enqueue, once per press.
            if isSwitcherActive && keyCode == Int64(kVK_Space) {
                if !isRepeat { enqueue(onExpandWindows) }
                return swallow()
            }

            // Cmd+Q/H/M while any switcher is active
            if isSwitcherActive || activeProfileHotkeyId != nil {
                if flags.contains(.maskCommand) {
                    switch keyCode {
                    case Int64(kVK_ANSI_Q):
                        if !isRepeat { enqueue(onQuitHighlighted) }
                        return swallow()
                    case Int64(kVK_ANSI_H):
                        if !isRepeat { enqueue(onHideHighlighted) }
                        return swallow()
                    case Int64(kVK_ANSI_M):
                        if !isRepeat { enqueue(onMinimizeHighlighted) }
                        return swallow()
                    default:
                        break
                    }
                }

                // Pin / unpin the highlighted app from inside the switcher.
                // Matched on key code alone so it works whether the held
                // modifier is Option (Option+Tab) or Command (Cmd+Tab, where
                // these arrive as Cmd+1, Cmd+P…). Only the main switcher —
                // per-profile hotkey overlays show a fixed app list.
                if isSwitcherActive {
                    if let slot = Self.profileSlot(forKeyCode: keyCode) {
                        if !isRepeat { enqueue(onToggleHighlightedInProfileSlot, with: slot) }
                        return swallow()
                    }
                    switch keyCode {
                    case Int64(kVK_ANSI_P):
                        if !isRepeat { enqueue(onToggleHighlightedInActiveProfile) }
                        return swallow()
                    case Int64(kVK_ANSI_N):
                        if !isRepeat { enqueue(onCreateWorkspaceWithHighlighted) }
                        return swallow()
                    case Int64(kVK_Delete), Int64(kVK_ForwardDelete):
                        if !isRepeat { enqueue(onUnpinHighlighted) }
                        return swallow()
                    default:
                        break
                    }
                }

                // Arrow key snapping while switcher is active.
                // Snap handlers do AX work — enqueue and return so the tap
                // callback never blocks on window moves. Key repeat is
                // swallowed (not passed through) so the held key neither
                // queues more snaps nor leaks into the focused app.
                switch keyCode {
                case Int64(kVK_LeftArrow):
                    if !isRepeat { enqueue(onSnapLeft) }
                    return swallow()
                case Int64(kVK_RightArrow):
                    if !isRepeat { enqueue(onSnapRight) }
                    return swallow()
                case Int64(kVK_UpArrow):
                    if !isRepeat { enqueue(onSnapFull) }
                    return swallow()
                case Int64(kVK_DownArrow):
                    if !isRepeat { enqueue(onSnapBottom) }
                    return swallow()
                default:
                    break
                }
            }

            // Modifier mask for exact matching (shift excluded — it's used for reverse cycling)
            let nonShiftModifiers = CGEventFlags([.maskControl, .maskAlternate, .maskCommand])

            // App switcher trigger
            let appEventMods = flags.intersection(nonShiftModifiers)
            let appRequiredMods = modifierFlag.intersection(nonShiftModifiers)
            if isModifierHeld && keyCode == triggerKeyCode && appEventMods == appRequiredMods {
                let shiftHeld = flags.contains(.maskShift)

                // Flag mutation stays synchronous — the next event must see
                // the switcher as active; only the handler moves off-callback.
                if !isSwitcherActive {
                    isSwitcherActive = true
                    activeSwitcherModifier = modifierFlag
                    enqueue(onSwitcherActivated)
                } else if shiftHeld {
                    enqueue(onCycleBackward)
                } else {
                    enqueue(onCycleForward)
                }
                return swallow()
            }

            // All-apps switcher trigger (⌘Tab). Matched on live flags; no
            // pre-held tracking needed because ⌘ is the only modifier.
            if let all = allAppsTrigger,
               keyCode == all.keyCode,
               appEventMods == all.modifierFlag.intersection(nonShiftModifiers) {
                let shiftHeld = flags.contains(.maskShift)
                if !isSwitcherActive {
                    isSwitcherActive = true
                    activeSwitcherModifier = all.modifierFlag
                    enqueue(onAllAppsSwitcherActivated)
                } else if shiftHeld {
                    enqueue(onCycleBackward)
                } else {
                    enqueue(onCycleForward)
                }
                return swallow()
            }

            // Command palette (⌥K by default, configurable). Exact modifier
            // match so ⌥⇧K or ⌘⌥K stay with the focused app. Not while a
            // switcher is held.
            if let palette = commandPaletteTrigger,
               !isSwitcherActive, !isProfileSwitcherActive, activeProfileHotkeyId == nil,
               keyCode == palette.keyCode,
               flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift])
                   == palette.modifierFlag.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]) {
                if !isRepeat { enqueue(onCommandPaletteActivated) }
                return swallow()
            }

            // Profile switcher trigger
            let profileEventMods = flags.intersection(nonShiftModifiers)
            let profileRequiredMods = profileModifierFlag.intersection(nonShiftModifiers)
            if isProfileModifierHeld && keyCode == profileTriggerKeyCode && profileEventMods == profileRequiredMods
                && !(isSwitcherActive && triggerKeyCode == profileTriggerKeyCode && modifierFlag == profileModifierFlag) {
                let shiftHeld = flags.contains(.maskShift)

                if !isProfileSwitcherActive {
                    isProfileSwitcherActive = true
                    enqueue(onProfileSwitcherActivated)
                } else if shiftHeld {
                    enqueue(onProfileCycleBackward)
                } else {
                    enqueue(onProfileCycleForward)
                }
                return swallow()
            }

            // Per-profile hotkey triggers
            let eventNonShiftMods = flags.intersection(nonShiftModifiers)
            for entry in profileHotkeys {
                let entryMods = entry.modifierFlag.intersection(nonShiftModifiers)
                guard eventNonShiftMods == entryMods && keyCode == entry.keyCode else { continue }
                // Skip if it matches the app or profile switcher shortcut
                if entry.modifierFlag == modifierFlag && entry.keyCode == triggerKeyCode { continue }
                if let all = allAppsTrigger, entry.modifierFlag == all.modifierFlag && entry.keyCode == all.keyCode { continue }
                if entry.modifierFlag == profileModifierFlag && entry.keyCode == profileTriggerKeyCode { continue }

                let shiftHeld = flags.contains(.maskShift)

                if activeProfileHotkeyId == nil {
                    // First press — activate this profile's switcher
                    activeProfileHotkeyId = entry.profileId
                    profileHotkeyModifierHeld = true
                    profileHotkeyModifier = entry.modifierFlag
                    enqueue(onProfileHotkeyActivated, with: entry.profileId)
                } else if activeProfileHotkeyId == entry.profileId {
                    // Repeat press — cycle
                    if shiftHeld {
                        enqueue(onProfileHotkeyCycleBackward, with: entry.profileId)
                    } else {
                        enqueue(onProfileHotkeyCycleForward, with: entry.profileId)
                    }
                }
                return swallow()
            }

            // Global snap shortcuts — only when no switcher is active
            if !isSwitcherActive && !isProfileSwitcherActive
                && activeProfileHotkeyId == nil && !isWindowPickerActive {
                // Shift must participate in matching: bindings like Undo (Ctrl+Opt+Z)
                // and Redo (Ctrl+Opt+Shift+Z) differ only by Shift.
                //
                // fn also participates, so a user can bind fn-based combos.
                // Critical subtlety: macOS sets the fn bit *by itself* for the
                // arrow keys, the nav cluster and F1-F20. Matching fn strictly
                // on those would break Ctrl+Opt+Left — the most-used binding in
                // the app — because the stored shortcut has no fn but every
                // incoming arrow event does. So fn is ignored for exactly those
                // keys, and honoured everywhere else.
                if let snap = matchedGlobalSnap(keyCode: keyCode, flags: flags) {
                    // If Accessibility was revoked, the snap can't do
                    // anything — pass the keystroke through instead of
                    // consuming it with zero effect. Cached: calling
                    // AXIsProcessTrusted() here would be an XPC round
                    // trip on the input path (see refreshTrust()).
                    guard isProcessTrusted else { return event }
                    // Key repeat: swallow it, but do not queue another
                    // window move — one snap per physical press.
                    if isRepeat { return swallow() }
                    // Enqueue the snap — the actual window move must not
                    // run inside the tap callback.
                    enqueue(onGlobalSnap, with: snap.direction)
                    return swallow()
                }
            }

            // Escape — cancel any active switcher
            if keyCode == kVK_Escape {
                if isSwitcherActive {
                    isSwitcherActive = false
                    activeSwitcherModifier = nil
                    isModifierHeld = false
                    enqueue(onSwitcherCancelled)
                    return swallow()
                }
                if isProfileSwitcherActive {
                    isProfileSwitcherActive = false
                    isProfileModifierHeld = false
                    enqueue(onProfileSwitcherCancelled)
                    return swallow()
                }
                if activeProfileHotkeyId != nil {
                    activeProfileHotkeyId = nil
                    profileHotkeyModifierHeld = false
                    profileHotkeyModifier = nil
                    enqueue(onSwitcherCancelled)
                    return swallow()
                }
            }
        }

        // MARK: Key Up — swallow trigger key releases while a switcher is active
        // so the foreground app never sees a stray keyUp for a keyDown we already consumed.
        if type == .keyUp {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // We consumed this key's keyDown — consume its keyUp too, even if
            // the handler that changes mode flags hasn't run yet.
            if swallowedKeyDowns.remove(keyCode) != nil {
                return nil
            }

            if isWindowPickerActive {
                return nil
            }
            if isSwitcherActive && (keyCode == triggerKeyCode || keyCode == allAppsTrigger?.keyCode) {
                return nil
            }
            if isProfileSwitcherActive && keyCode == profileTriggerKeyCode {
                return nil
            }
            if let activeId = activeProfileHotkeyId,
               profileHotkeys.contains(where: { $0.profileId == activeId && $0.keyCode == keyCode }) {
                return nil
            }
        }

        return event
    }
}

// MARK: - C Callback

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
    if let result = service.handleEvent(type: type, event: event) {
        return Unmanaged.passUnretained(result)
    }
    return nil // swallow
}

/// Callback for the separate listen-only mouse tap. A listen-only tap's
/// return value is ignored by the system — it can never modify or swallow
/// the event — which is exactly what drag-to-snap needs.
private func mouseTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
    service.handleMouseTapEvent(type: type, event: event)
    return Unmanaged.passUnretained(event)
}
