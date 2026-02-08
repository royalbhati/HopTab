import AppKit
import Combine

final class PermissionsService: ObservableObject {
    @Published private(set) var isTrusted: Bool = false
    private var timer: Timer?

    private static let hasPromptedKey = "hasPromptedAccessibility"

    init() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Show the system Accessibility prompt only on first launch ever.
    /// On subsequent launches, just poll silently.
    func promptIfNeeded() {
        guard !isTrusted else { return }

        if !UserDefaults.standard.bool(forKey: Self.hasPromptedKey) {
            // First time — show the system dialog
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            isTrusted = AXIsProcessTrustedWithOptions(opts)
            UserDefaults.standard.set(true, forKey: Self.hasPromptedKey)
        }

        if !isTrusted {
            startPolling()
        }
    }

    /// Explicitly re-show the system Accessibility prompt (user-triggered from Settings).
    func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        isTrusted = AXIsProcessTrustedWithOptions(opts)
        if !isTrusted {
            startPolling()
        }
    }

    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if AXIsProcessTrusted() {
                self.isTrusted = true
                self.timer?.invalidate()
                self.timer = nil
            }
        }
    }

    deinit {
        timer?.invalidate()
    }
}
