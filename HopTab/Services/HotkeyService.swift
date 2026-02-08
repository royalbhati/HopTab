import Cocoa
import Carbon.HIToolbox

final class HotkeyService {
    // Callbacks
    var onSwitcherActivated: (() -> Void)?
    var onCycleForward: (() -> Void)?
    var onCycleBackward: (() -> Void)?
    var onSwitcherDismissed: (() -> Void)?
    var onSwitcherCancelled: (() -> Void)?
    var onTapFailed: (() -> Void)?

    // Configurable shortcut
    private(set) var modifierFlag: CGEventFlags = .maskAlternate
    private(set) var triggerKeyCode: Int64 = Int64(kVK_Tab)

    // State
    private(set) var isModifierHeld = false
    private(set) var isSwitcherActive = false

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

        NSLog("[HotkeyService] Event tap started — listening for modifier=0x%llx key=%lld",
              modifierFlag.rawValue, triggerKeyCode)
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
            let modifierDown = flags.contains(modifierFlag)

            if modifierDown && !isModifierHeld {
                isModifierHeld = true
            } else if !modifierDown && isModifierHeld {
                isModifierHeld = false
                if isSwitcherActive {
                    isSwitcherActive = false
                    onSwitcherDismissed?()
                    return nil // swallow the release
                }
            }
            return event
        }

        // MARK: Key Down
        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

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
                return nil // swallow
            }

            // Escape — cancel
            if keyCode == kVK_Escape && isSwitcherActive {
                isSwitcherActive = false
                isModifierHeld = false
                onSwitcherCancelled?()
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
