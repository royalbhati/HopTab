import Cocoa
import Carbon.HIToolbox

final class HotkeyService {
    // App Switcher Callbacks
    var onSwitcherActivated: (() -> Void)?
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

    // Snap Callbacks (arrow keys while switcher active)
    var onSnapLeft: (() -> Void)?
    var onSnapRight: (() -> Void)?
    var onSnapFull: (() -> Void)?

    // App Switcher shortcut (configurable)
    private(set) var modifierFlag: CGEventFlags = .maskAlternate
    private(set) var triggerKeyCode: Int64 = Int64(kVK_Tab)

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

    // Event tap
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

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

    func configureProfileShortcut(modifierFlag: CGEventFlags, keyCode: Int64) {
        let wasRunning = eventTap != nil
        if wasRunning { stop() }
        profileModifierFlag = modifierFlag
        profileTriggerKeyCode = keyCode
        if wasRunning { start() }
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

        NSLog("[HotkeyService] Event tap started — app modifier=0x%llx key=%lld, profile modifier=0x%llx key=%lld",
              modifierFlag.rawValue, triggerKeyCode,
              profileModifierFlag.rawValue, profileTriggerKeyCode)
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
        isModifierHeld = false
        isSwitcherActive = false
        isProfileModifierHeld = false
        isProfileSwitcherActive = false
        isWindowPickerActive = false
        activeProfileHotkeyId = nil
        profileHotkeyModifierHeld = false
        profileHotkeyModifier = nil
    }

    var isRunning: Bool { eventTap != nil }

    func enterWindowPickerMode() {
        isWindowPickerActive = true
    }

    func exitWindowPickerMode() {
        isWindowPickerActive = false
    }

    // MARK: - Event Processing

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> CGEvent? {
        // Re-enable tap if macOS disabled it due to timeout
        if type == .tapDisabledByTimeout {
            if let tap = eventTap {
                if isWindowPickerActive {
                    isWindowPickerActive = false
                    onWindowPickerCancel?()
                }
                if isSwitcherActive {
                    isSwitcherActive = false
                    onSwitcherCancelled?()
                }
                if isProfileSwitcherActive {
                    isProfileSwitcherActive = false
                    onProfileSwitcherCancelled?()
                }
                isModifierHeld = false
                isProfileModifierHeld = false

                CGEvent.tapEnable(tap: tap, enable: true)
                NSLog("[HotkeyService] Re-enabled event tap after timeout — reset modifier state")
            }
            return event
        }

        let flags = event.flags

        // MARK: Flags Changed (modifier key up/down)
        if type == .flagsChanged {
            // App switcher modifier tracking
            let appModDown = flags.contains(modifierFlag)
            if appModDown && !isModifierHeld {
                isModifierHeld = true
            } else if !appModDown && isModifierHeld {
                isModifierHeld = false
                if isSwitcherActive {
                    isSwitcherActive = false
                    onSwitcherDismissed?()
                    return nil
                }
            }

            // Profile switcher modifier tracking
            let profileModDown = flags.contains(profileModifierFlag)
            if profileModDown && !isProfileModifierHeld {
                isProfileModifierHeld = true
            } else if !profileModDown && isProfileModifierHeld {
                isProfileModifierHeld = false
                if isProfileSwitcherActive {
                    isProfileSwitcherActive = false
                    onProfileSwitcherDismissed?()
                    return nil
                }
            }

            // Per-profile hotkey modifier release tracking
            if let mod = profileHotkeyModifier, let profileId = activeProfileHotkeyId {
                if !flags.contains(mod) {
                    activeProfileHotkeyId = nil
                    profileHotkeyModifierHeld = false
                    profileHotkeyModifier = nil
                    onProfileHotkeyDismissed?(profileId)
                    return nil
                }
            }

            return event
        }


        if type == .keyDown || type == .keyUp {
            let actualAppMod = flags.contains(modifierFlag)
            if isModifierHeld && !actualAppMod {
                isModifierHeld = false
                if isSwitcherActive {
                    isSwitcherActive = false
                    onSwitcherDismissed?()
                }
            } else if !isModifierHeld && actualAppMod {
                isModifierHeld = true
            }

            let actualProfileMod = flags.contains(profileModifierFlag)
            if isProfileModifierHeld && !actualProfileMod {
                isProfileModifierHeld = false
                if isProfileSwitcherActive {
                    isProfileSwitcherActive = false
                    onProfileSwitcherDismissed?()
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
                    onProfileHotkeyDismissed?(profileId)
                }
            }
        }

        // MARK: Key Down
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // Window picker mode — intercept all keys, only allow Up/Down/Enter/Escape
            if isWindowPickerActive {
                switch keyCode {
                case Int64(kVK_UpArrow):
                    onWindowPickerNavigateUp?()
                case Int64(kVK_DownArrow):
                    onWindowPickerNavigateDown?()
                case Int64(kVK_Return), Int64(kVK_ANSI_KeypadEnter):
                    onWindowPickerSelect?()
                case Int64(kVK_Escape):
                    onWindowPickerCancel?()
                default:
                    break // swallow all other keys
                }
                return nil
            }

            // Cmd+Q/H/M while any switcher is active
            if isSwitcherActive || activeProfileHotkeyId != nil {
                if flags.contains(.maskCommand) {
                    switch keyCode {
                    case Int64(kVK_ANSI_Q):
                        onQuitHighlighted?()
                        return nil
                    case Int64(kVK_ANSI_H):
                        onHideHighlighted?()
                        return nil
                    case Int64(kVK_ANSI_M):
                        onMinimizeHighlighted?()
                        return nil
                    default:
                        break
                    }
                }

                // Arrow key snapping while switcher is active
                switch keyCode {
                case Int64(kVK_LeftArrow):
                    onSnapLeft?()
                    return nil
                case Int64(kVK_RightArrow):
                    onSnapRight?()
                    return nil
                case Int64(kVK_UpArrow):
                    onSnapFull?()
                    return nil
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

                if !isSwitcherActive {
                    isSwitcherActive = true
                    onSwitcherActivated?()
                } else if shiftHeld {
                    onCycleBackward?()
                } else {
                    onCycleForward?()
                }
                return nil
            }

            // Profile switcher trigger
            let profileEventMods = flags.intersection(nonShiftModifiers)
            let profileRequiredMods = profileModifierFlag.intersection(nonShiftModifiers)
            if isProfileModifierHeld && keyCode == profileTriggerKeyCode && profileEventMods == profileRequiredMods
                && !(isSwitcherActive && triggerKeyCode == profileTriggerKeyCode && modifierFlag == profileModifierFlag) {
                let shiftHeld = flags.contains(.maskShift)

                if !isProfileSwitcherActive {
                    isProfileSwitcherActive = true
                    onProfileSwitcherActivated?()
                } else if shiftHeld {
                    onProfileCycleBackward?()
                } else {
                    onProfileCycleForward?()
                }
                return nil
            }

            // Per-profile hotkey triggers
            let eventNonShiftMods = flags.intersection(nonShiftModifiers)
            for entry in profileHotkeys {
                let entryMods = entry.modifierFlag.intersection(nonShiftModifiers)
                guard eventNonShiftMods == entryMods && keyCode == entry.keyCode else { continue }
                // Skip if it matches the app or profile switcher shortcut
                if entry.modifierFlag == modifierFlag && entry.keyCode == triggerKeyCode { continue }
                if entry.modifierFlag == profileModifierFlag && entry.keyCode == profileTriggerKeyCode { continue }

                let shiftHeld = flags.contains(.maskShift)

                if activeProfileHotkeyId == nil {
                    // First press — activate this profile's switcher
                    activeProfileHotkeyId = entry.profileId
                    profileHotkeyModifierHeld = true
                    profileHotkeyModifier = entry.modifierFlag
                    onProfileHotkeyActivated?(entry.profileId)
                } else if activeProfileHotkeyId == entry.profileId {
                    // Repeat press — cycle
                    if shiftHeld {
                        onProfileHotkeyCycleBackward?(entry.profileId)
                    } else {
                        onProfileHotkeyCycleForward?(entry.profileId)
                    }
                }
                return nil
            }

            // Escape — cancel any active switcher
            if keyCode == kVK_Escape {
                if isSwitcherActive {
                    isSwitcherActive = false
                    isModifierHeld = false
                    onSwitcherCancelled?()
                    return nil
                }
                if isProfileSwitcherActive {
                    isProfileSwitcherActive = false
                    isProfileModifierHeld = false
                    onProfileSwitcherCancelled?()
                    return nil
                }
                if activeProfileHotkeyId != nil {
                    activeProfileHotkeyId = nil
                    profileHotkeyModifierHeld = false
                    profileHotkeyModifier = nil
                    onSwitcherCancelled?()
                    return nil
                }
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
