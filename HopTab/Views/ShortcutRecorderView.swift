import SwiftUI
import AppKit
import Carbon.HIToolbox

struct ShortcutRecorderView: View {
    @Binding var shortcut: CustomShortcut?
    @State private var isRecording = false
    @State private var liveModifiers: String = ""
    @State private var rejectionHint: String = ""
    @State private var flagsMonitor: Any?
    @State private var keyMonitor: Any?

    var body: some View {
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
        .onDisappear { stopRecording() }
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
            let cg = nsModifiersToCGFlags(event.modifierFlags)
            let names = KeyCodeMapping.modifierDisplayNames(for: cg)
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

            // Strip shift from stored flags — shift is used for reverse cycling
            var storedFlags = cgFlags
            storedFlags.remove(.maskShift)

            shortcut = CustomShortcut(
                modifierFlagsRawValue: storedFlags.rawValue,
                keyCode: Int64(keyCode)
            )
            stopRecording()
            return nil
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
