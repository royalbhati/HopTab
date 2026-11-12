import AppKit
import SwiftUI

@main
struct HopTabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(delegate.appState)
        } label: {
            MenuBarLabel(
                appState: delegate.appState,
                permissions: delegate.appState.permissions
            )
        }
        // A real SwiftUI popover, not an NSMenu. Custom views inside an NSMenu
        // get no hover or keyboard highlight, so the whole panel looked pasted
        // on and could not be driven from the keyboard.
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Status item

/// The menu-bar status item.
///
/// Three states, in priority order:
///  1. An imminent meeting — icon plus "<meeting> in 4m" (Pro).
///  2. Accessibility missing — a warning glyph, because nothing else works.
///  3. A focus session or Pomodoro running — the filled variant of the same
///     glyph, so the identity holds but the state is visible.
///
/// Everything is an SF Symbol, so the image is a template that inverts
/// correctly on light and dark menu bars without a custom asset.
private struct MenuBarLabel: View {
    @ObservedObject var appState: AppState
    @ObservedObject var permissions: PermissionsService
    @StateObject private var ticker = MenuBarTicker()

    /// Reads as three tiled windows at 16pt — a window manager, not the
    /// generic `arrow.2.squarepath` sync glyph this used to ship with.
    private static let idleSymbol = "rectangle.3.group"
    private static let busySymbol = "rectangle.3.group.fill"
    private static let blockedSymbol = "exclamationmark.triangle.fill"

    var body: some View {
        if let hud = appState.meetingHUD {
            HStack(spacing: 4) {
                Image(systemName: "video.fill")
                Text(hud)
            }
            .accessibilityLabel("HopTab — \(hud)")
        } else {
            Image(systemName: Self.resolve(symbolName))
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var symbolName: String {
        if !permissions.isTrusted { return Self.blockedSymbol }
        return isBusy ? Self.busySymbol : Self.idleSymbol
    }

    private var accessibilityLabel: String {
        if !permissions.isTrusted { return "HopTab — Accessibility permission needed" }
        return isBusy ? "HopTab — session running" : "HopTab"
    }

    /// A focus session or a Pomodoro is running.
    private var isBusy: Bool {
        guard let provider = ProServiceRegistry.shared.provider, provider.isLicensed else {
            return false
        }
        return provider.focusSessionRemainingMinutes != nil || provider.pomodoroStatus != nil
    }

    /// Never render an empty status item if a symbol is missing on this OS.
    private static func resolve(_ name: String) -> String {
        NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil ? name : "macwindow"
    }
}

/// Focus sessions and Pomodoros live in the Pro module and publish nothing the
/// status item can observe, so drive a slow, heavily-tolerant repaint. One
/// timer, coalesced with the system's other 15 s wake-ups.
@MainActor
private final class MenuBarTicker: ObservableObject {
    private var timer: Timer?

    init() {
        let t = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.objectWillChange.send() }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit {
        timer?.invalidate()
    }
}
