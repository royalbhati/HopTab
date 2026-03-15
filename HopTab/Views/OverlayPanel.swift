import AppKit
import SwiftUI

/// NSHostingView subclass that accepts the first mouse click without
/// requiring the window to be key — needed for non-activating panels.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// A non-activating, borderless floating panel for the app switcher overlay.
final class OverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Returns the screen the mouse cursor is on, falling back to the main screen.
    static var activeScreen: NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
            ?? NSScreen()
    }
}

// MARK: - Shared positioning helper

private func centerOnScreen(_ panel: NSPanel, fittingSize: NSSize) {
    let screenFrame = OverlayPanel.activeScreen.frame
    let panelFrame = NSRect(
        x: (screenFrame.width - fittingSize.width) / 2 + screenFrame.origin.x,
        y: (screenFrame.height - fittingSize.height) / 2 + screenFrame.origin.y,
        width: fittingSize.width,
        height: fittingSize.height
    )
    panel.setFrame(panelFrame, display: true, animate: false)
}

// MARK: - App Switcher View Model

final class OverlayViewModel: ObservableObject {
    @Published var apps: [PinnedApp] = []
    @Published var selectedIndex: Int = 0
    @Published var showHints: Bool = false
    var onAppClicked: ((Int) -> Void)?
}

// MARK: - Window Controller

final class OverlayWindowController {
    private var panel: OverlayPanel?
    private let viewModel = OverlayViewModel()
    var onAppClicked: ((Int) -> Void)? {
        didSet { viewModel.onAppClicked = onAppClicked }
    }
    var showHints: Bool = false

    func show(apps: [PinnedApp], selectedIndex: Int) {
        dismiss()

        viewModel.apps = apps
        viewModel.selectedIndex = selectedIndex
        viewModel.showHints = showHints
        viewModel.onAppClicked = onAppClicked

        let panel = OverlayPanel()
        let overlayView = OverlayView(viewModel: viewModel)
        let hostingView = FirstMouseHostingView(rootView: overlayView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        panel.contentView = hostingView

        centerOnScreen(panel, fittingSize: hostingView.fittingSize)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(apps: [PinnedApp], selectedIndex: Int) {
        guard let panel else { return }

        viewModel.apps = apps
        viewModel.selectedIndex = selectedIndex
        viewModel.showHints = showHints

        // Let SwiftUI settle, then resize the panel to fit
        DispatchQueue.main.async {
            guard let hostingView = panel.contentView as? NSHostingView<OverlayView> else { return }
            centerOnScreen(panel, fittingSize: hostingView.fittingSize)
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
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
    private let viewModel = ProfileOverlayViewModel()

    func show(profiles: [Profile], selectedIndex: Int) {
        dismiss()

        viewModel.profiles = profiles
        viewModel.selectedIndex = selectedIndex

        let panel = OverlayPanel()
        let overlayView = ProfileOverlayView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        panel.contentView = hostingView

        centerOnScreen(panel, fittingSize: hostingView.fittingSize)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(profiles: [Profile], selectedIndex: Int) {
        guard let panel else { return }

        viewModel.profiles = profiles
        viewModel.selectedIndex = selectedIndex

        DispatchQueue.main.async {
            guard let hostingView = panel.contentView as? NSHostingView<ProfileOverlayView> else { return }
            centerOnScreen(panel, fittingSize: hostingView.fittingSize)
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Sticky Note Overlay Controller

final class StickyNoteOverlayController {
    private var panel: OverlayPanel?
    private var dismissTask: Task<Void, Never>?

    func show(profileName: String, note: String, duration: TimeInterval = 3.0) {
        dismiss()

        let panel = OverlayPanel()
        let view = StickyNoteOverlayView(profileName: profileName, note: note)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        panel.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        let screenFrame = OverlayPanel.activeScreen.frame
        let panelFrame = NSRect(
            x: screenFrame.maxX - fittingSize.width - 20,
            y: screenFrame.maxY - fittingSize.height - 40,
            width: fittingSize.width,
            height: fittingSize.height
        )
        panel.setFrame(panelFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

// MARK: - Toast Overlay Controller

final class ToastOverlayController {
    private var panel: OverlayPanel?
    private var dismissTask: Task<Void, Never>?

    func show(icon: String, message: String, duration: TimeInterval = 1.5) {
        dismiss()

        let panel = OverlayPanel()
        let view = ToastOverlayView(icon: icon, message: message)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        panel.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        let screenFrame = OverlayPanel.activeScreen.frame
        let panelFrame = NSRect(
            x: screenFrame.midX - fittingSize.width / 2,
            y: screenFrame.minY + 120,
            width: fittingSize.width,
            height: fittingSize.height
        )
        panel.setFrame(panelFrame, display: true)
        panel.orderFrontRegardless()
        self.panel = panel

        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self.dismiss()
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        panel?.orderOut(nil)
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
    private let viewModel = WindowPickerViewModel()

    func show(appName: String, appIcon: NSImage, windows: [WindowInfo], selectedIndex: Int) {
        dismiss()

        viewModel.appName = appName
        viewModel.appIcon = appIcon
        viewModel.windows = windows
        viewModel.selectedIndex = selectedIndex

        let panel = OverlayPanel()
        let view = WindowPickerView(viewModel: viewModel)
        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1, height: 1)
        panel.contentView = hostingView

        centerOnScreen(panel, fittingSize: hostingView.fittingSize)
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(appName: String, appIcon: NSImage, windows: [WindowInfo], selectedIndex: Int) {
        guard let panel else { return }

        viewModel.appName = appName
        viewModel.appIcon = appIcon
        viewModel.windows = windows
        viewModel.selectedIndex = selectedIndex

        DispatchQueue.main.async {
            guard let hostingView = panel.contentView as? NSHostingView<WindowPickerView> else { return }
            centerOnScreen(panel, fittingSize: hostingView.fittingSize)
        }
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}
