import AppKit
import ApplicationServices

/// Detects window drags to screen edges/corners and snaps them.
final class DragSnapService {
    var isEnabled: Bool = false

    private enum State { case idle, detecting, dragging }
    private var state: State = .idle

    private var initialMousePos: CGPoint = .zero
    private var initialWindowFrame: CGRect = .zero
    private var draggedWindow: AXUIElement?
    private var draggedPID: pid_t = 0
    private var currentZone: SnapDirection?
    private var currentScreen: NSScreen?

    private let previewController = SnapPreviewController()
    private let edgeThreshold: CGFloat = 3    // pixels from screen edge to trigger half snap
    private let cornerThreshold: CGFloat = 60 // corner zone size (px from corner)
    private let dragDetectThreshold: CGFloat = 5

    // MARK: - Mouse Event Handler

    func handleMouseEvent(type: CGEventType, event: CGEvent) {
        guard isEnabled else { return }

        switch type {
        case .leftMouseDown:
            handleMouseDown(event)
        case .leftMouseDragged:
            handleMouseDragged(event)
        case .leftMouseUp:
            handleMouseUp(event)
        default:
            break
        }
    }

    // MARK: - State Machine

    private func handleMouseDown(_ event: CGEvent) {
        initialMousePos = event.location
        state = .detecting
        draggedWindow = nil
        currentZone = nil
    }

    private func handleMouseDragged(_ event: CGEvent) {
        let pos = event.location

        switch state {
        case .idle:
            return

        case .detecting:
            // Check if cursor moved enough to be a drag
            let dx = pos.x - initialMousePos.x
            let dy = pos.y - initialMousePos.y
            guard (dx * dx + dy * dy) > (dragDetectThreshold * dragDetectThreshold) else { return }

            // Check if a window is being dragged
            if detectWindowDrag() {
                state = .dragging
                checkZone(at: pos)
            } else {
                state = .idle
            }

        case .dragging:
            checkZone(at: pos)
        }
    }

    private func handleMouseUp(_ event: CGEvent) {
        defer {
            state = .idle
            draggedWindow = nil
            currentZone = nil
            currentScreen = nil
            previewController.hide()
        }

        guard state == .dragging,
              let zone = currentZone,
              let window = draggedWindow,
              let screen = currentScreen
        else { return }

        let screenFrame = LayoutService.quartzVisibleFrame(for: screen)
        LayoutService.snapWindow(window, pid: draggedPID, to: zone, on: screenFrame)
    }

    // MARK: - Window Drag Detection

    private func detectWindowDrag() -> Bool {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return false }
        let pid = frontApp.processIdentifier
        let axApp = AXUIElementCreateApplication(pid)

        // Get focused window
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let window = focusedRef
        else { return false }

        let axWindow = window as! AXUIElement
        let frame = LayoutService.windowFrame(axWindow)
        guard !frame.isEmpty else { return false }

        // Check if window position changed from initial mouse down
        // (if the window moved roughly with the cursor, user is dragging it)
        let windowMoved = abs(frame.origin.x - initialWindowFrame.origin.x) > 2 ||
                          abs(frame.origin.y - initialWindowFrame.origin.y) > 2

        if initialWindowFrame.isEmpty {
            // First check — store the frame and wait for next drag event
            initialWindowFrame = frame
            return false
        }

        if windowMoved {
            draggedWindow = axWindow
            draggedPID = pid
            return true
        }

        return false
    }

    // MARK: - Zone Detection

    private func checkZone(at cursorPos: CGPoint) {
        // Find which screen the cursor is on
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaY = primaryHeight - cursorPos.y
        let cocoaPoint = NSPoint(x: cursorPos.x, y: cocoaY)

        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cocoaPoint, $0.frame, false) }) else {
            clearZone()
            return
        }

        // Use the full screen frame (not visible) for edge detection
        // so the menu bar and Dock edges still trigger
        let screenFrame = screen.frame
        // Convert screen frame to Quartz coords
        let quartzTop = primaryHeight - screenFrame.maxY
        let quartzBottom = primaryHeight - screenFrame.minY
        let quartzLeft = screenFrame.minX
        let quartzRight = screenFrame.maxX

        let x = cursorPos.x
        let y = cursorPos.y

        let nearLeft = x <= quartzLeft + edgeThreshold
        let nearRight = x >= quartzRight - edgeThreshold
        let nearTop = y <= quartzTop + edgeThreshold
        let nearBottom = y >= quartzBottom - edgeThreshold

        let newZone: SnapDirection?

        // Corners: cursor within cornerThreshold of both edges
        if nearTop && x < quartzLeft + cornerThreshold {
            newZone = .topLeft
        } else if nearTop && x > quartzRight - cornerThreshold {
            newZone = .topRight
        } else if nearBottom && x < quartzLeft + cornerThreshold {
            newZone = .bottomLeft
        } else if nearBottom && x > quartzRight - cornerThreshold {
            newZone = .bottomRight
        }
        // Edges (not corners)
        else if nearLeft {
            newZone = .left
        } else if nearRight {
            newZone = .right
        } else if nearTop {
            newZone = .full
        } else if nearBottom {
            newZone = .bottomHalf
        } else {
            newZone = nil
        }

        if newZone != currentZone || (newZone != nil && screen != currentScreen) {
            currentZone = newZone
            currentScreen = screen

            if let zone = newZone {
                let visibleFrame = LayoutService.quartzVisibleFrame(for: screen)
                let snapRect = LayoutService.computeSnapFrame(for: zone, in: visibleFrame)
                previewController.show(rect: snapRect, on: screen)
            } else {
                previewController.hide()
            }
        }
    }

    private func clearZone() {
        if currentZone != nil {
            currentZone = nil
            currentScreen = nil
            previewController.hide()
        }
    }
}

// MARK: - Snap Preview Controller

final class SnapPreviewController {
    private var panel: NSPanel?

    func show(rect quartzRect: CGRect, on screen: NSScreen) {
        // Convert Quartz rect to Cocoa screen coordinates
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaRect = CGRect(
            x: quartzRect.origin.x,
            y: primaryHeight - quartzRect.origin.y - quartzRect.height,
            width: quartzRect.width,
            height: quartzRect.height
        )

        if panel == nil {
            let p = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: true
            )
            p.isFloatingPanel = true
            p.level = .floating
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.hidesOnDeactivate = false
            p.ignoresMouseEvents = true
            panel = p
        }

        guard let panel else { return }

        // Create the preview content
        let previewView = NSView(frame: NSRect(origin: .zero, size: cocoaRect.size))
        previewView.wantsLayer = true
        previewView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
        previewView.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor
        previewView.layer?.borderWidth = 2
        previewView.layer?.cornerRadius = 10

        panel.contentView = previewView
        panel.setFrame(cocoaRect, display: true)
        panel.alphaValue = 1

        if !panel.isVisible {
            panel.orderFrontRegardless()
            // Animate in
            panel.alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.1
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel?.orderOut(nil)
        })
    }
}
