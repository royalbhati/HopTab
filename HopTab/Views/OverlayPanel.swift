import AppKit
import SwiftUI

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
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Window Controller

final class OverlayWindowController {
    private var panel: OverlayPanel?

    func show(apps: [PinnedApp], selectedIndex: Int) {
        let panel = OverlayPanel()

        let overlayView = OverlayView(apps: apps, selectedIndex: selectedIndex)
        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 1, height: 1) // will resize
        panel.contentView = hostingView

        // Size to fit the content
        let fittingSize = hostingView.fittingSize
        let screenFrame = NSScreen.main?.frame ?? .zero
        let panelFrame = NSRect(
            x: (screenFrame.width - fittingSize.width) / 2 + screenFrame.origin.x,
            y: (screenFrame.height - fittingSize.height) / 2 + screenFrame.origin.y,
            width: fittingSize.width,
            height: fittingSize.height
        )
        panel.setFrame(panelFrame, display: true)

        panel.orderFrontRegardless()
        self.panel = panel
    }

    func update(apps: [PinnedApp], selectedIndex: Int) {
        guard let panel else { return }

        let overlayView = OverlayView(apps: apps, selectedIndex: selectedIndex)
        let hostingView = NSHostingView(rootView: overlayView)
        panel.contentView = hostingView

        let fittingSize = hostingView.fittingSize
        let screenFrame = NSScreen.main?.frame ?? .zero
        let panelFrame = NSRect(
            x: (screenFrame.width - fittingSize.width) / 2 + screenFrame.origin.x,
            y: (screenFrame.height - fittingSize.height) / 2 + screenFrame.origin.y,
            width: fittingSize.width,
            height: fittingSize.height
        )
        panel.setFrame(panelFrame, display: true, animate: false)
    }

    func dismiss() {
        panel?.orderOut(nil)
        panel = nil
    }
}
