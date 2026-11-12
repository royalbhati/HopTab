import AppKit
import Combine

final class PermissionsService: ObservableObject {
    @Published private(set) var isTrusted: Bool = false
    private var timer: Timer?

    private static let hasPromptedKey = "hasPromptedAccessibility"

    /// True once macOS has shown the system Accessibility dialog for this app.
    ///
    /// macOS shows that dialog **once per app installation**. Every later call to
    /// `AXIsProcessTrustedWithOptions(prompt:)` is a silent no-op, which turns a
    /// "Grant Access" button into a dead end. UI should read this and offer
    /// `openAccessibilitySettings()` instead once it is true.
    var hasPromptedBefore: Bool {
        UserDefaults.standard.bool(forKey: Self.hasPromptedKey)
    }

    /// Whether a "Grant Access" button can still produce the system dialog.
    /// When false, send the user to System Settings instead.
    var canShowSystemPrompt: Bool { !isTrusted && !hasPromptedBefore }

    init() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Show the system Accessibility prompt only on first launch ever.
    /// On subsequent launches, just poll silently.
    func promptIfNeeded() {
        guard !isTrusted else { return }

        if !hasPromptedBefore {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            isTrusted = AXIsProcessTrustedWithOptions(opts)
            UserDefaults.standard.set(true, forKey: Self.hasPromptedKey)
        }

        if !isTrusted {
            startPolling()
        }
    }

    /// User-triggered request from onboarding or Settings.
    ///
    /// Shows the system dialog the first time. After that the dialog can never
    /// appear again, so this opens System Settings directly at the Accessibility
    /// pane rather than doing nothing.
    func requestAccessibility() {
        guard !isTrusted else { return }

        if hasPromptedBefore {
            openAccessibilitySettings()
        } else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            isTrusted = AXIsProcessTrustedWithOptions(opts)
            UserDefaults.standard.set(true, forKey: Self.hasPromptedKey)
        }

        if !isTrusted {
            startPolling()
        }
    }

    /// Open System Settings directly at Privacy & Security › Accessibility.
    ///
    /// Works on macOS 13+ (System Settings) and older System Preferences via the
    /// same URL scheme. Falls back to the Privacy & Security pane, then to
    /// System Settings itself, so the button always does something visible.
    func openAccessibilitySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                startPolling()
                return
            }
        }
        if let settings = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.systempreferences"
        ) {
            NSWorkspace.shared.openApplication(at: settings, configuration: .init())
        }
        startPolling()
    }

    /// Poll for the trust flag flipping. macOS sends no notification when the
    /// user toggles the Accessibility switch, so polling is the only option.
    /// Runs at 1 s with generous tolerance so it coalesces with other timers,
    /// and stops the moment trust is granted.
    func startPolling() {
        guard timer == nil, !isTrusted else { return }
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard AXIsProcessTrusted() else { return }
            DispatchQueue.main.async {
                self.isTrusted = true
                self.stopPolling()
            }
        }
        t.tolerance = 0.5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-read trust state on demand, e.g. when a window becomes key.
    @discardableResult
    func refresh() -> Bool {
        let trusted = AXIsProcessTrusted()
        if trusted != isTrusted {
            isTrusted = trusted
        }
        if trusted { stopPolling() }
        return trusted
    }

    deinit {
        timer?.invalidate()
    }
}
