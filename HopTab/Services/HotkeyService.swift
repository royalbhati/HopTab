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

    func configureProfileShortcut(modifierFlag: CGEventFlags, keyCode: Int64) {
        let wasRunning = eventTap != nil
        if wasRunning { stop() }
        profileModifierFlag = modifierFlag
        profileTriggerKeyCode = keyCode
        if wasRunning { start() }
    }

    func start() {
        guard eventTap == nil else { return }

        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)

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
    }

    var isRunning: Bool { eventTap != nil }

    // MARK: - Event Processing

    fileprivate func handleEvent(type: CGEventType, event: CGEvent) -> CGEvent? {
        // Re-enable tap if macOS disabled it due to timeout
        if type == .tapDisabledByTimeout {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                NSLog("[HotkeyService] Re-enabled event tap after timeout")
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

            return event
        }

        // MARK: Key Down
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // App switcher trigger
            if isModifierHeld && keyCode == triggerKeyCode {
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
            if isProfileModifierHeld && keyCode == profileTriggerKeyCode
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

            // Escape — cancel either active switcher
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
