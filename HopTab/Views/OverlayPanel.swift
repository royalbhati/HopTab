import AppKit
import SwiftUI

/// NSHostingView subclass that accepts the first mouse click without
/// requiring the window to be key — needed for non-activating panels.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Overlay roles

/// What kind of overlay a panel is. Drives window level and which screen the
/// panel lands on — a toast and a switcher want neither the same altitude nor
/// the same display.
enum OverlayRole {
    /// Option+Tab app switcher. Keyboard-invoked.
    case switcher
    /// Profile switcher. Keyboard-invoked.
    case profileSwitcher
    /// Per-app window picker. Keyboard-invoked.
    case windowPicker
    /// Profile sticky note. Follows a profile switch.
    case stickyNote
    /// Transient confirmation toast.
    case toast

    /// Window level.
    ///
    /// Switcher-type overlays sit at `.popUpMenu` — the level AppKit uses for
    /// menus: above every ordinary, floating and status-bar window, but below
    /// system alerts, the screen-recording picker, and the screen saver.
    /// (`.screenSaver` used to put them above all of those, which is wrong.)
    ///
    /// Passive overlays sit lower still, at `.floating`, so a toast or a
    /// sticky note never covers an open menu or a modal sheet.
    var windowLevel: NSWindow.Level {
        switch self {
        case .switcher, .profileSwitcher, .windowPicker:
            return .popUpMenu
        case .stickyNote, .toast:
            return .floating
        }
    }

    /// Whether the overlay should follow the pointer instead of the keyboard.
    ///
    /// Keyboard-invoked overlays follow the keyboard focus, which is what
    /// macOS's own Cmd+Tab does. Only the toast follows the pointer, because
    /// it usually confirms a pointer action (drag-snap, a menu-bar click).
    var prefersMouseScreen: Bool {
        switch self {
        case .toast: return true
        case .switcher, .profileSwitcher, .windowPicker, .stickyNote: return false
        }
    }
}

/// A non-activating, borderless floating panel for HopTab's HUD overlays.
final class OverlayPanel: NSPanel {
    let role: OverlayRole

    init(role: OverlayRole) {
        self.role = role
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = role.windowLevel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        // The *window* draws the shadow. A SwiftUI `.shadow` cannot: the panel
        // frame is exactly the hosting view's fittingSize, so anything drawn
        // outside the content bounds is clipped away and never seen.
        hasShadow = true
        // `.hudWindow` is a dark material in both appearances, which is why
        // overlay text is white-based. Pin the panel to dark aqua so the
        // material, any system-drawn control, and the text agree — including
        // when the rest of the system is in light mode.
        appearance = NSAppearance(named: .darkAqua)
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Fade in. Use instead of bare `orderFrontRegardless()`.
    /// Bumped by `present()`; a `fadeOut()` that started before a newer
    /// `present()` must not order the panel out from under it.
    private var presentationGeneration: UInt64 = 0

    func present() {
        presentationGeneration &+= 1
        alphaValue = 0
        orderFrontRegardless()
        invalidateShadow()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = HopMotion.reduceMotion ? 0.01 : 0.13
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 1
        }
        // The content is layer-backed, so the window shadow is derived from
        // the first drawn frame — re-derive it once SwiftUI has painted.
        DispatchQueue.main.async { [weak self] in self?.invalidateShadow() }
    }

    /// Fade out, then order out. Strongly captures self so the panel
    /// survives until the animation completes even after the owning
    /// controller drops its reference.
    func fadeOut() {
        let gen = presentationGeneration
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = HopMotion.reduceMotion ? 0.01 : 0.1
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            animator().alphaValue = 0
        }, completionHandler: {
            guard self.presentationGeneration == gen else { return }
            self.orderOut(nil)
        })
    }

    /// The screen this panel should appear on, per its role.
    var targetScreen: NSScreen { OverlayPanel.screen(for: role) }

    /// Move/resize the panel. Re-centres are animated once the panel is
    /// already on screen so a size change (e.g. the hint row appearing)
    /// glides instead of jumping.
    func setOverlayFrame(_ newFrame: NSRect, animated: Bool) {
        guard newFrame != frame else { return }
        if animated, isVisible, !HopMotion.reduceMotion {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().setFrame(newFrame, display: true)
            }
        } else {
            setFrame(newFrame, display: true)
        }
        invalidateShadow()
    }

    // MARK: - Screen selection

    /// Picks the screen an overlay of this role belongs on.
    static func screen(for role: OverlayRole) -> NSScreen {
        if role.prefersMouseScreen, let mouse = mouseScreen { return mouse }
        return keyboardScreen
            ?? mouseScreen
            ?? NSScreen.screens.first
            ?? NSScreen()
    }

    /// The screen the pointer is on.
    static var mouseScreen: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
    }

    /// The screen that has keyboard focus.
    ///
    /// When HopTab itself is active (Settings/onboarding open) that is our own
    /// key window. Otherwise `NSScreen.main` is the documented "screen holding
    /// the window with keyboard focus", which is what Cmd+Tab follows. Falls
    /// back to the pointer's screen at the call site if both are nil.
    static var keyboardScreen: NSScreen? {
        if NSApp?.isActive == true,
           let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen {
            return screen
        }
        return NSScreen.main
    }
}

// MARK: - Shared sizing / positioning helpers

/// Margin kept between an overlay and the edge of the screen's visible frame.
private let overlayScreenMargin: CGFloat = 40

/// Inset used by the corner-anchored overlays (toast, sticky note).
private let overlayEdgeInset: CGFloat = 20

/// Widest content an overlay on `screen` may be.
func overlayMaxContentWidth(for screen: NSScreen) -> CGFloat {
    max(260, screen.visibleFrame.width - overlayScreenMargin * 2)
}

/// Forces the hosting view through a layout pass so `fittingSize` is final
/// *before* the panel is sized. Without this the first measurement is taken
/// against a 1x1 frame and the panel has to be re-centred a run loop later,
/// which reads as a visible jump.
private func settledSize<V: View>(_ hostingView: NSHostingView<V>) -> NSSize {
    hostingView.layoutSubtreeIfNeeded()
    let first = hostingView.fittingSize
    hostingView.setFrameSize(first)
    hostingView.layoutSubtreeIfNeeded()
    let second = hostingView.fittingSize
    hostingView.setFrameSize(second)
    return second
}

/// Clamp a content size to the target screen's visible frame minus the margin.
private func clamped(_ size: NSSize, in visible: NSRect) -> NSSize {
    NSSize(
        width: min(size.width, visible.width - overlayScreenMargin * 2),
        height: min(size.height, visible.height - overlayScreenMargin * 2)
    )
}

/// Centre an overlay on its target screen's *visible* frame (which already
/// excludes the menu bar and the Dock).
private func centerOverlay(_ panel: OverlayPanel, size: NSSize, animated: Bool) {
    let visible = panel.targetScreen.visibleFrame
    let fitted = clamped(size, in: visible)
    let frame = NSRect(
        x: visible.midX - fitted.width / 2,
        y: visible.midY - fitted.height / 2,
        width: fitted.width,
        height: fitted.height
    ).integral
    panel.setOverlayFrame(frame, animated: animated)
}

/// Anchor an overlay to a corner of its target screen's visible frame.
private func anchorOverlay(
    _ panel: OverlayPanel,
    size: NSSize,
    corner: (bottom: Bool, trailing: Bool),
    inset: CGFloat = overlayEdgeInset,
    animated: Bool = false
) {
    let visible = panel.targetScreen.visibleFrame
    let fitted = clamped(size, in: visible)
    let x = corner.trailing
        ? visible.maxX - fitted.width - inset
        : visible.midX - fitted.width / 2
    let y = corner.bottom
        ? visible.minY + inset
        : visible.maxY - fitted.height - inset
    let frame = NSRect(x: x, y: y, width: fitted.width, height: fitted.height).integral
    panel.setOverlayFrame(frame, animated: animated)
}

// MARK: - App Switcher View Model

/// Which profiles exist and which is active — what the switcher needs to
/// label its pinned group and to render the "1 Coding · 2 Design" hint.
struct SwitcherProfileContext: Equatable {
    var profiles: [Profile] = []
    var activeProfileId: UUID?
    var canAddWorkspace: Bool = true

    var activeProfile: Profile? { profiles.first { $0.id == activeProfileId } }

    /// Profiles addressable from the digit row, in slot order.
    var slots: [Profile] { Array(profiles.prefix(9)) }

    func isPinned(_ bundleId: String, in profile: Profile) -> Bool {
        profile.pinnedApps.contains { $0.bundleIdentifier == bundleId }
    }
}

final class OverlayViewModel: ObservableObject {
    @Published var entries: [SwitcherEntry] = []
    @Published var selectedIndex: Int = 0
    @Published var showHints: Bool = false
    @Published var context = SwitcherProfileContext()
    /// One-line confirmation after a pin/unpin ("Pinned to Coding"). Cleared
    /// on the next selection change.
    @Published var feedback: String?
    /// Widest the icon rows may grow before wrapping. Set from the target
    /// screen so the switcher can never run off the side of the display.
    @Published var maxContentWidth: CGFloat = 1200
    var onAppClicked: ((Int) -> Void)?

    var apps: [PinnedApp] { entries.map(\.app) }
}

// MARK: - Window Controller

final class OverlayWindowController {
    private var panel: OverlayPanel?
    private var hostingView: FirstMouseHostingView<OverlayView>?
    private let viewModel = OverlayViewModel()
    var onAppClicked: ((Int) -> Void)? {
        didSet { viewModel.onAppClicked = onAppClicked }
    }
    var showHints: Bool = false

    /// True between `show` and `dismiss`. The panel and its SwiftUI host
    /// outlive both: building them fresh on every ⌥Tab was the largest
    /// single cost of opening the switcher (a full first layout pass of
    /// every tile, 20–100 ms on the main thread).
    private var isPresented = false

    /// Build the panel and run one layout pass before the first ⌥Tab, so
    /// the first open after launch costs the same as every later one.
    func prewarm() {
        guard panel == nil else { return }
        let panel = OverlayPanel(role: .switcher)
        let hostingView = FirstMouseHostingView(rootView: OverlayView(viewModel: viewModel))
        panel.contentView = hostingView
        viewModel.maxContentWidth = overlayMaxContentWidth(for: panel.targetScreen)
        _ = settledSize(hostingView)
        self.panel = panel
        self.hostingView = hostingView
    }

    func show(entries: [SwitcherEntry], selectedIndex: Int, context: SwitcherProfileContext) {
        let panel: OverlayPanel
        let hostingView: FirstMouseHostingView<OverlayView>
        if let existing = self.panel, let existingHost = self.hostingView {
            panel = existing
            hostingView = existingHost
        } else {
            panel = OverlayPanel(role: .switcher)
            hostingView = FirstMouseHostingView(rootView: OverlayView(viewModel: viewModel))
            panel.contentView = hostingView
            self.panel = panel
            self.hostingView = hostingView
        }
        isPresented = true

        viewModel.entries = entries
        viewModel.selectedIndex = selectedIndex
        viewModel.context = context
        viewModel.feedback = nil
        viewModel.showHints = showHints
        viewModel.maxContentWidth = overlayMaxContentWidth(for: panel.targetScreen)
        viewModel.onAppClicked = onAppClicked

        // Measure after a real layout pass so the panel is the right size the
        // first time it is shown — no post-show re-centre, no jump.
        centerOverlay(panel, size: settledSize(hostingView), animated: false)
        panel.present()
    }

    func update(entries: [SwitcherEntry], selectedIndex: Int, context: SwitcherProfileContext) {
        guard isPresented else { return }

        if selectedIndex != viewModel.selectedIndex { viewModel.feedback = nil }
        viewModel.entries = entries
        viewModel.selectedIndex = selectedIndex
        viewModel.context = context
        viewModel.showHints = showHints

        // Let SwiftUI settle, then resize the panel to fit. Animated, so a
        // size change (hint row, an extra icon row) glides into place.
        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, let hostingView = self.hostingView else { return }
            self.viewModel.maxContentWidth = overlayMaxContentWidth(for: panel.targetScreen)
            centerOverlay(panel, size: settledSize(hostingView), animated: true)
        }
    }

    /// Confirm a pin/unpin in the footer. Call before `update` so both land
    /// in the same layout pass.
    func flashPinFeedback(pinned: Bool, profileName: String) {
        viewModel.feedback = pinned ? "Pinned to \(profileName)" : "Removed from \(profileName)"
    }

    func flashPinFeedback(message: String) {
        viewModel.feedback = message
    }

    func dismiss() {
        guard isPresented else { return }
        isPresented = false
        panel?.fadeOut()
    }
}

// MARK: - Profile Overlay View Model

final class ProfileOverlayViewModel: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published var selectedIndex: Int = 0
}

// MARK: - Profile Overlay Window Controller

final class ProfileOverlayWindowController {
    private var panel: OverlayPanel?
    private var hostingView: FirstMouseHostingView<ProfileOverlayView>?
    private let viewModel = ProfileOverlayViewModel()

    func show(profiles: [Profile], selectedIndex: Int) {
        dismiss()

        viewModel.profiles = profiles
        viewModel.selectedIndex = selectedIndex

        let panel = OverlayPanel(role: .profileSwitcher)
        let overlayView = ProfileOverlayView(viewModel: viewModel)
        let hostingView = FirstMouseHostingView(rootView: overlayView)
        panel.contentView = hostingView

        centerOverlay(panel, size: settledSize(hostingView), animated: false)
        panel.present()
        self.panel = panel
        self.hostingView = hostingView
    }

    func update(profiles: [Profile], selectedIndex: Int) {
        guard panel != nil else { return }

        viewModel.profiles = profiles
        viewModel.selectedIndex = selectedIndex

        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, let hostingView = self.hostingView else { return }
            centerOverlay(panel, size: settledSize(hostingView), animated: true)
        }
    }

    func dismiss() {
        panel?.fadeOut()
        panel = nil
        hostingView = nil
    }
}

// MARK: - Sticky Note Overlay Controller

final class StickyNoteOverlayController {
    private var panel: OverlayPanel?
    private var dismissTask: Task<Void, Never>?

    func show(profileName: String, note: String, duration: TimeInterval = 3.0) {
        dismiss()

        let panel = OverlayPanel(role: .stickyNote)
        let view = StickyNoteOverlayView(profileName: profileName, note: note)
        let hostingView = FirstMouseHostingView(rootView: view)
        panel.contentView = hostingView

        // Bottom-trailing of the *visible* frame: clear of the Dock and the
        // menu bar, and out of the top-right strip Notification Center uses
        // for banners.
        anchorOverlay(panel, size: settledSize(hostingView), corner: (bottom: true, trailing: true))
        panel.present()
        self.panel = panel

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.fadeOut()
        panel = nil
    }
}

// MARK: - Toast Overlay Controller

final class ToastOverlayController {
    private var panel: OverlayPanel?
    private var dismissTask: Task<Void, Never>?

    func show(icon: String, message: String, duration: TimeInterval = 1.5) {
        dismiss()

        let panel = OverlayPanel(role: .toast)
        let view = ToastOverlayView(icon: icon, message: message)
        let hostingView = FirstMouseHostingView(rootView: view)
        panel.contentView = hostingView

        // Bottom-centre of the visible frame, which already excludes the Dock.
        anchorOverlay(panel, size: settledSize(hostingView), corner: (bottom: true, trailing: false), inset: 24)
        panel.present()
        self.panel = panel

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.fadeOut()
        panel = nil
    }
}

// MARK: - Window Picker View Model

final class WindowPickerViewModel: ObservableObject {
    @Published var appName: String = ""
    @Published var appIcon: NSImage = NSImage()
    @Published var windows: [WindowInfo] = []
    @Published var selectedIndex: Int = 0
}

// MARK: - Window Picker Overlay Controller

final class WindowPickerOverlayController {
    private var panel: OverlayPanel?
    private var hostingView: FirstMouseHostingView<WindowPickerView>?
    private let viewModel = WindowPickerViewModel()

    func show(appName: String, appIcon: NSImage, windows: [WindowInfo], selectedIndex: Int) {
        dismiss()

        viewModel.appName = appName
        viewModel.appIcon = appIcon
        viewModel.windows = windows
        viewModel.selectedIndex = selectedIndex

        let panel = OverlayPanel(role: .windowPicker)
        let view = WindowPickerView(viewModel: viewModel)
        let hostingView = FirstMouseHostingView(rootView: view)
        panel.contentView = hostingView

        centerOverlay(panel, size: settledSize(hostingView), animated: false)
        panel.present()
        self.panel = panel
        self.hostingView = hostingView
    }

    func update(appName: String, appIcon: NSImage, windows: [WindowInfo], selectedIndex: Int) {
        guard panel != nil else { return }

        viewModel.appName = appName
        viewModel.appIcon = appIcon
        viewModel.windows = windows
        viewModel.selectedIndex = selectedIndex

        DispatchQueue.main.async { [weak self] in
            guard let self, let panel = self.panel, let hostingView = self.hostingView else { return }
            centerOverlay(panel, size: settledSize(hostingView), animated: true)
        }
    }

    func dismiss() {
        panel?.fadeOut()
        panel = nil
        hostingView = nil
    }
}
