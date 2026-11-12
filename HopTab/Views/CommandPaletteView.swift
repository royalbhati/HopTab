import AppKit
import Carbon.HIToolbox
import SwiftUI

// MARK: - Panel

/// The ⌥K palette's window. Unlike the switcher overlays it must take
/// keyboard focus for its text field, so it can become key; it stays a
/// non-activating panel so the app behind it keeps its menu bar and comes
/// straight back when the palette closes.
final class CommandPalettePanel: NSPanel {
    var onResignKey: (() -> Void)?

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - View model

@MainActor
final class CommandPaletteViewModel: ObservableObject {
    @Published var query: String = "" {
        didSet { rerank() }
    }
    @Published private(set) var rows: [CommandPaletteItem] = []
    @Published var selectedIndex: Int = 0
    @Published var isLoading = false
    @Published var shortcutHint: String = "\u{2325}K"

    private var all: [CommandPaletteItem] = []
    /// Bundle id of the app that had focus when the palette opened.
    var frontmostBundleIdentifier: String? {
        didSet { rerank(keepSelection: true) }
    }
    var onPerform: ((CommandPaletteItem, Bool) -> Void)?
    var onClose: (() -> Void)?
    var onCloseTab: ((CommandPaletteItem) -> Void)?
    /// ⌘N: turn the current query into a new custom command.
    var onSaveAsCommand: ((String) -> Void)?

    func setItems(_ items: [CommandPaletteItem]) {
        all = items
        scheduleRerank()
    }

    private var rerankScheduled = false

    /// The index publishes several times while the palette opens (base rows,
    /// then tabs, windows, Chrome…). Re-ranking and re-rendering on each
    /// one is wasted work; do it once per run-loop turn instead.
    private func scheduleRerank() {
        guard !rerankScheduled else { return }
        rerankScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.rerankScheduled = false
            self.rerank(keepSelection: true)
        }
    }

    /// Where the pointer was when the rows last changed. Hover only moves
    /// the selection once the pointer has actually moved from here, so a
    /// row that happens to appear under a resting pointer is not selected
    /// out from under the keyboard.
    var hoverArmedAt: NSPoint = NSEvent.mouseLocation

    func hoverSelect(_ index: Int) {
        guard NSEvent.mouseLocation != hoverArmedAt else { return }
        selectedIndex = index
    }

    private func rerank(keepSelection: Bool = false) {
        hoverArmedAt = NSEvent.mouseLocation
        let previous = rows.indices.contains(selectedIndex) ? rows[selectedIndex].id : nil
        var ranked = CommandPaletteItem.rank(all, query: query, frontmost: frontmostBundleIdentifier)
        if let fallback = CommandPaletteItem.fallback(for: query) {
            ranked.append(fallback)
        }
        rows = ranked
        if keepSelection, let previous, let idx = rows.firstIndex(where: { $0.id == previous }) {
            selectedIndex = idx
        } else if !keepSelection {
            selectedIndex = 0
        } else {
            selectedIndex = min(selectedIndex, max(rows.count - 1, 0))
        }
    }

    var selected: CommandPaletteItem? {
        rows.indices.contains(selectedIndex) ? rows[selectedIndex] : nil
    }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + rows.count) % rows.count
    }

    func perform(alternate: Bool = false) {
        guard let item = selected else { return }
        onPerform?(item, alternate)
    }

    func jump(to slot: Int) {
        let idx = slot - 1
        guard rows.indices.contains(idx) else { return }
        selectedIndex = idx
        perform()
    }
}

// MARK: - Window controller

@MainActor
final class CommandPaletteController {
    private var panel: CommandPalettePanel?
    private var hostingView: NSHostingView<CommandPaletteView>?
    let viewModel = CommandPaletteViewModel()
    private var keyMonitor: Any?
    /// True between show() and dismiss(); the panel object outlives both.
    private var isPresented = false

    var isVisible: Bool { isPresented }

    /// Build the panel and its SwiftUI host ahead of the first ⌥K. The
    /// first open otherwise pays ~150 ms of view construction on main.
    func prewarm() {
        guard panel == nil else { return }
        let panel = CommandPalettePanel()
        let hosting = NSHostingView(rootView: CommandPaletteView(viewModel: viewModel))
        panel.contentView = hosting
        panel.setFrame(NSRect(x: 0, y: 0, width: 640, height: 440), display: false)
        hosting.layoutSubtreeIfNeeded()
        self.panel = panel
        self.hostingView = hosting
    }

    func show() {
        if let panel, panel.isVisible, isPresented {
            panel.makeKeyAndOrderFront(nil)
            return
        }
        // The panel and its SwiftUI host are built once and kept: building
        // them cost ~60 ms of main thread on every ⌥K, most of the open delay.
        let panel: CommandPalettePanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = CommandPalettePanel()
            let hosting = NSHostingView(rootView: CommandPaletteView(viewModel: viewModel))
            panel.contentView = hosting
            self.panel = panel
            self.hostingView = hosting
        }
        panel.onResignKey = { [weak self] in self?.dismiss() }
        isPresented = true

        viewModel.query = ""
        viewModel.selectedIndex = 0
        viewModel.hoverArmedAt = NSEvent.mouseLocation

        let screen = OverlayPanel.keyboardScreen ?? OverlayPanel.mouseScreen ?? NSScreen.main ?? NSScreen()
        let visible = screen.visibleFrame
        let width = min(640, visible.width - 80)
        let height: CGFloat = 440
        // Spotlight sits above centre; so do we.
        let frame = NSRect(
            x: visible.midX - width / 2,
            y: visible.minY + visible.height * 0.62 - height / 2,
            width: width,
            height: height
        ).integral
        panel.setFrame(frame, display: true)

        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = HopMotion.reduceMotion ? 0.01 : 0.12
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        // Navigation keys. A local monitor beats SwiftUI `onKeyPress` here:
        // the text field keeps focus and never sees the arrows.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            return self.handle(event) ? nil : event
        }

    }

    func dismiss() {
        guard let panel, isPresented else { return }
        isPresented = false
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        panel.onResignKey = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = HopMotion.reduceMotion ? 0.01 : 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard self?.isPresented == false else { return }
            panel.orderOut(nil)
        })
    }

    func toggle() {
        if isVisible { dismiss() } else { show() }
    }

    /// Returns true when the event was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        let cmd = event.modifierFlags.contains(.command)
        switch Int(event.keyCode) {
        case kVK_Escape:
            viewModel.onClose?()
            return true
        case kVK_DownArrow:
            viewModel.moveSelection(by: 1)
            return true
        case kVK_UpArrow:
            viewModel.moveSelection(by: -1)
            return true
        case kVK_Tab:
            viewModel.moveSelection(by: event.modifierFlags.contains(.shift) ? -1 : 1)
            return true
        case kVK_Return, kVK_ANSI_KeypadEnter:
            viewModel.perform(alternate: cmd)
            return true
        case kVK_ANSI_N where event.modifierFlags.contains(.control):
            viewModel.moveSelection(by: 1)
            return true
        case kVK_ANSI_N where cmd:
            viewModel.onSaveAsCommand?(viewModel.query)
            return true
        case kVK_ANSI_P where event.modifierFlags.contains(.control):
            viewModel.moveSelection(by: -1)
            return true
        case kVK_Delete where cmd:
            if let item = viewModel.selected, case .activateChromeTab = item.action {
                viewModel.onCloseTab?(item)
                return true
            }
            return false
        default:
            break
        }
        if cmd, let digit = Self.digit(for: event.keyCode) {
            viewModel.jump(to: digit)
            return true
        }
        return false
    }

    private static func digit(for keyCode: UInt16) -> Int? {
        switch Int(keyCode) {
        case kVK_ANSI_1: return 1
        case kVK_ANSI_2: return 2
        case kVK_ANSI_3: return 3
        case kVK_ANSI_4: return 4
        case kVK_ANSI_5: return 5
        case kVK_ANSI_6: return 6
        case kVK_ANSI_7: return 7
        case kVK_ANSI_8: return 8
        case kVK_ANSI_9: return 9
        default: return nil
        }
    }
}

// MARK: - View

struct CommandPaletteView: View {
    @ObservedObject var viewModel: CommandPaletteViewModel
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider().overlay(Color.white.opacity(0.08))
            results
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { VisualEffectBlur(cornerRadius: HopRadius.panel) }
        .clipShape(RoundedRectangle(cornerRadius: HopRadius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: HopRadius.panel, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .onAppear { fieldFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: HopSpacing.md) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(HopOverlay.secondaryText)
            TextField("Workspaces, apps, tabs, history\u{2026}", text: $viewModel.query)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(HopOverlay.primaryText)
                .focused($fieldFocused)
                .accessibilityLabel("Search")
            if viewModel.isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(HopOverlay.secondaryText)
            }
        }
        .padding(.horizontal, HopSpacing.lg + 2)
        .padding(.vertical, HopSpacing.md + 2)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(viewModel.rows.enumerated()), id: \.element.id) { index, item in
                        CommandPaletteRow(
                            item: item,
                            isSelected: index == viewModel.selectedIndex,
                            slot: index < 9 ? index + 1 : nil
                        )
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            viewModel.selectedIndex = index
                            viewModel.perform()
                        }
                        .onHover { inside in
                            if inside { viewModel.hoverSelect(index) }
                        }
                    }
                    if viewModel.rows.isEmpty {
                        Text("Nothing matches")
                            .font(.hopSubheading)
                            .foregroundStyle(HopOverlay.tertiaryText)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, HopSpacing.xl)
                    }
                }
                .padding(HopSpacing.sm)
            }
            .onChange(of: viewModel.selectedIndex) { _, idx in
                guard viewModel.rows.indices.contains(idx) else { return }
                proxy.scrollTo(viewModel.rows[idx].id, anchor: nil)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: HopSpacing.lg) {
            hint("\u{21A9}", selectedVerb)
            if let item = viewModel.selected, case .activateChromeTab = item.action {
                hint("\u{2318}\u{232B}", "close tab")
            } else if let item = viewModel.selected, case .openURL = item.action {
                hint("\u{2318}\u{21A9}", "new window")
            }
            hint("\u{2318}1\u{2013}9", "jump")
            hint("\u{2318}N", "new command")
            Spacer()
            Text(viewModel.shortcutHint)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(HopOverlay.tertiaryText)
        }
        .padding(.horizontal, HopSpacing.lg)
        .padding(.vertical, HopSpacing.sm)
    }

    private var selectedVerb: String {
        guard let item = viewModel.selected else { return "open" }
        switch item.action {
        case .switchWorkspace: return "switch workspace"
        case .activateApp: return item.subtitle == "Running" ? "switch to app" : "open app"
        case .activateChromeTab: return "go to tab"
        case .openURL: return "open in Chrome"
        case .openProject: return "open project"
        case .switchChromeProfile, .switchSafariProfile: return "switch profile"
        case .raiseWindow: return "go to window"
        case .selectNativeTab: return "go to tab"
        case .snap: return "snap"
        case .newWorkspaceFromRunning: return "create"
        case .openSettings, .openOnboarding: return "open"
        case .runCustomCommand: return "run"
        }
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(HopOverlay.primaryText)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.white.opacity(0.14))
                )
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(HopOverlay.secondaryText)
        }
    }
}

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool
    let slot: Int?

    var body: some View {
        HStack(spacing: HopSpacing.md) {
            iconView
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(HopOverlay.primaryText)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(HopOverlay.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: HopSpacing.sm)
            if !item.kindLabel.isEmpty {
                Text(item.kindLabel.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(HopOverlay.tertiaryText)
            }
            if let slot {
                Text("\u{2318}\(slot)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(isSelected ? HopOverlay.secondaryText : HopOverlay.tertiaryText.opacity(0.6))
                    .frame(width: 26)
            }
        }
        .padding(.horizontal, HopSpacing.md)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                .fill(isSelected ? Color.white.opacity(0.16) : Color.clear)
        )
    }

    @ViewBuilder
    private var iconView: some View {
        switch item.icon {
        case .image(let image):
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(HopOverlay.secondaryText)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
    }
}
