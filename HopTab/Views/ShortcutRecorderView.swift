import SwiftUI
import AppKit
import Carbon.HIToolbox

/// How the recorder treats the Shift key.
///
/// This distinction is load-bearing, so it is a parameter rather than a global
/// rule. `HotkeyService` matches the two families of shortcut differently:
///
/// * **Snap / window actions** (`HotkeyService`, "Global snap shortcuts") match
///   over `[.maskControl, .maskAlternate, .maskCommand, .maskShift]` and require
///   an **exact** match. Shift is part of the binding. Undo is ⌃⌥Z and Redo is
///   ⌃⌥⇧Z — they differ *only* by Shift, so a recorder that strips Shift turns
///   a recorded Redo into a second Undo and one of the two stops working.
///
/// * **Switcher-style bindings** — the app switcher, the profile switcher and
///   per-profile hotkeys — match over `[.maskControl, .maskAlternate,
///   .maskCommand]` only, because Shift is the *reverse cycling* modifier:
///   ⌥⇧Tab has to mean "⌥Tab, backwards". Their base binding must therefore be
///   recorded without Shift, or the shortcut would only fire while Shift is
///   held.
enum ShortcutRecorderMode {
    /// Shift is stored and matched exactly. Use for every snap/window action.
    case exactModifiers
    /// Shift is stripped at record time; the binding fires with or without it.
    /// Use for the app switcher, the profile switcher and per-profile hotkeys.
    case shiftInsensitive
}

struct ShortcutRecorderView: View {
    @Binding var shortcut: CustomShortcut?

    /// Defaults to `.exactModifiers` — the correct behaviour for snap actions,
    /// which are the overwhelming majority of recorders in Settings. Switcher
    /// recorders must pass `.shiftInsensitive` explicitly.
    var mode: ShortcutRecorderMode = .exactModifiers

    /// Capture the fn (Globe) key as part of the combination when the user
    /// actually holds it. Keys that set the fn bit on their own (arrows, F-keys,
    /// the navigation cluster) never count — see
    /// `KeyCodeMapping.keysImplyingFunctionModifier`.
    var capturesFunctionModifier: Bool = true

    /// Capture which physical side each modifier was pressed on. Off by default:
    /// `HotkeyService` matches on the device-independent masks, so side data is
    /// recorded for display and future use but is not yet enforced. Turning this
    /// on would make the recorder promise behaviour the matcher does not deliver.
    var capturesModifierSide: Bool = false

    @State private var isRecording = false
    @State private var liveModifiers: String = ""
    @State private var rejectionHint: String = ""
    @State private var shiftNote: String = ""
    @State private var flagsMonitor: Any?
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            recorderButton
            if !shiftNote.isEmpty {
                Text(shiftNote)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .onDisappear { stopRecording() }
    }

    private var recorderButton: some View {
        Button(action: toggleRecording) {
            HStack(spacing: 6) {
                if isRecording {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                    if !rejectionHint.isEmpty {
                        Text(rejectionHint)
                            .foregroundStyle(.orange)
                    } else {
                        Text(liveModifiers.isEmpty ? "Press a key combo\u{2026}" : "\(liveModifiers) + \u{2026}")
                            .foregroundStyle(.primary)
                    }
                } else if let s = shortcut {
                    Text(s.displayName)
                        .foregroundStyle(.primary)
                } else {
                    Text("Record Shortcut")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isRecording ? Color.red.opacity(0.1) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? Color.red.opacity(0.4) : Color.primary.opacity(0.15), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }

    private func startRecording() {
        // Clean up any existing monitors to prevent leaks on rapid toggle
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }

        isRecording = true
        liveModifiers = ""

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            var cg = nsModifiersToCGFlags(event.modifierFlags)
            if mode == .shiftInsensitive { cg.remove(.maskShift) }
            // fn alone is ambiguous until a trigger key arrives, but showing it
            // live is what the user expects while holding Globe.
            let fn = capturesFunctionModifier && event.modifierFlags.contains(.function)
            let device = capturesModifierSide ? deviceBits(of: event) : 0
            let names = KeyCodeMapping.modifierDisplayNames(for: cg, function: fn, deviceFlags: device)
            liveModifiers = names.joined(separator: " + ")
            return event
        }

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = Int(event.keyCode)

            // Escape cancels recording
            if keyCode == kVK_Escape {
                stopRecording()
                return nil
            }

            // Reject modifier-only and forbidden keys
            if KeyCodeMapping.modifierKeyCodes.contains(keyCode) {
                return nil
            }
            if KeyCodeMapping.forbiddenKeyCodes.contains(keyCode) {
                showRejection("That key can't be used")
                return nil
            }

            let cgFlags = nsModifiersToCGFlags(event.modifierFlags)

            // Require at least one modifier (but not shift-only)
            let hasControl = cgFlags.contains(.maskControl)
            let hasOption = cgFlags.contains(.maskAlternate)
            let hasCommand = cgFlags.contains(.maskCommand)
            if !hasControl && !hasOption && !hasCommand {
                showRejection("Add a modifier (Ctrl/Opt/Cmd)")
                return nil
            }

            // Shift handling — the whole point of `mode`.
            //
            // `.exactModifiers`: Shift is kept, because snap matching in
            //   HotkeyService compares Shift exactly. Stripping it here is what
            //   made a re-recorded ⌃⌥⇧Z (Redo) collapse onto ⌃⌥Z (Undo).
            // `.shiftInsensitive`: Shift is dropped, because switcher matching
            //   ignores Shift (it means "cycle backward") and a Shift in the base
            //   binding would stop the switcher from ever activating.
            let hadShift = cgFlags.contains(.maskShift)
            var storedFlags = cgFlags
            let strippedShift = (mode == .shiftInsensitive) && hadShift
            if strippedShift { storedFlags.remove(.maskShift) }

            // fn (Globe). Only intentional presses count: macOS sets the fn bit
            // by itself for the arrows, the navigation cluster and F1–F20.
            let fnImpliedByKey = KeyCodeMapping.keysImplyingFunctionModifier.contains(keyCode)
            let usedFunction = capturesFunctionModifier
                && event.modifierFlags.contains(.function)
                && !fnImpliedByKey

            // Left/right modifier sides, opt-in.
            let deviceFlags = capturesModifierSide ? deviceBits(of: event) : 0

            let recorded = CustomShortcut(
                modifierFlagsRawValue: storedFlags.rawValue,
                keyCode: Int64(keyCode),
                usesFunctionModifier: usedFunction ? true : nil,
                deviceModifierFlagsRawValue: deviceFlags == 0 ? nil : deviceFlags
            )
            shortcut = recorded
            stopRecording()

            // Be honest about what actually got saved.
            if strippedShift {
                showShiftNote("\u{21E7} is reserved for reverse cycling \u{2014} saved as \(recorded.displayName)")
            } else if usedFunction {
                showShiftNote("Saved as \(recorded.displayName). fn is recorded but not yet required to match.")
            }
            return nil
        }
    }

    /// Device-dependent (`NX_DEVICE*`) modifier bits from the raw event flags.
    /// `NSEvent.ModifierFlags.rawValue` carries them in its low 16 bits; the
    /// device-independent masks `CGEventFlags` exposes live in the high bits.
    private func deviceBits(of event: NSEvent) -> UInt64 {
        UInt64(event.modifierFlags.rawValue) & KeyCodeMapping.deviceModifierMask
    }

    private func showShiftNote(_ note: String) {
        withAnimation(.easeInOut(duration: 0.15)) { shiftNote = note }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            if shiftNote == note {
                withAnimation(.easeInOut(duration: 0.15)) { shiftNote = "" }
            }
        }
    }

    private func showRejection(_ hint: String) {
        rejectionHint = hint
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if rejectionHint == hint { rejectionHint = "" }
        }
    }

    private func stopRecording() {
        isRecording = false
        liveModifiers = ""
        rejectionHint = ""
        if let m = flagsMonitor { NSEvent.removeMonitor(m); flagsMonitor = nil }
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    private func nsModifiersToCGFlags(_ ns: NSEvent.ModifierFlags) -> CGEventFlags {
        var cg = CGEventFlags()
        if ns.contains(.control)  { cg.insert(.maskControl) }
        if ns.contains(.option)   { cg.insert(.maskAlternate) }
        if ns.contains(.shift)    { cg.insert(.maskShift) }
        if ns.contains(.command)  { cg.insert(.maskCommand) }
        return cg
    }
}
