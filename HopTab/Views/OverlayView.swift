import SwiftUI

// MARK: - Overlay surface
//
// Chrome for a floating overlay: HUD blur + continuous rounded corners, and
// deliberately NO SwiftUI shadow. The panel frame is exactly the hosting
// view's fittingSize, so a `.shadow` would be clipped at the window edge and
// never seen; `OverlayPanel` sets `hasShadow = true` and the window server
// draws the shadow outside the frame instead.
//
// This is `Theme.swift`'s `overlayChrome()` minus the shadow — see the report
// note about folding it back in there.

private struct OverlaySurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background { VisualEffectBlur(cornerRadius: HopRadius.panel) }
            .clipShape(RoundedRectangle(cornerRadius: HopRadius.panel, style: .continuous))
    }
}

private extension View {
    func overlaySurface() -> some View { modifier(OverlaySurface()) }
}

// MARK: - Switcher overflow rule

/// How the switcher row lays out for a given app count and width budget.
///
/// Item pitch is `iconSize + 2 * HopSpacing.md` of padding plus
/// `HopSpacing.xs` of inter-item spacing. We try 64pt icons first, then 48,
/// then 36, and take the first size whose wrapped row count fits within
/// `maxRows`. The smallest size is used regardless if nothing fits, so no
/// pinned app is ever dropped — every index stays reachable by keyboard.
struct SwitcherLayout {
    static let iconSizeLadder: [CGFloat] = [64, 48, 36]
    static let maxRows = 3

    let iconSize: CGFloat
    /// Items per row. Rows are balanced, so 20 apps in a 15-wide budget lay
    /// out as 10 + 10 rather than 15 + 5.
    let columns: Int

    init(count: Int, maxWidth: CGFloat) {
        let items = max(count, 1)
        // The container's own horizontal padding is not available to icons.
        let usable = max(maxWidth - HopSpacing.lg * 2, 120)

        var size = Self.iconSizeLadder[Self.iconSizeLadder.count - 1]
        var perRow = 1
        for candidate in Self.iconSizeLadder {
            let pitch = candidate + HopSpacing.md * 2 + HopSpacing.xs
            let capacity = max(1, Int((usable + HopSpacing.xs) / pitch))
            size = candidate
            perRow = capacity
            if Int(ceil(Double(items) / Double(capacity))) <= Self.maxRows { break }
        }

        let rows = max(1, Int(ceil(Double(items) / Double(perRow))))
        iconSize = size
        columns = max(1, min(perRow, Int(ceil(Double(items) / Double(rows)))))
    }
}

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @Namespace private var selection

    private var layout: SwitcherLayout {
        SwitcherLayout(count: viewModel.entries.count, maxWidth: viewModel.maxContentWidth)
    }

    private var pinnedIndices: [Int] { viewModel.entries.indices.filter { viewModel.entries[$0].isPinned } }
    private var otherIndices: [Int] { viewModel.entries.indices.filter { !viewModel.entries[$0].isPinned } }

    /// Indices chunked into rows, left-to-right then top-to-bottom, so the
    /// switcher's index-based keyboard navigation reads in the same order.
    private func rows(_ indices: [Int]) -> [[Int]] {
        let columns = layout.columns
        return stride(from: 0, to: indices.count, by: columns).map { start in
            Array(indices[start ..< min(start + columns, indices.count)])
        }
    }

    private var activeProfileName: String { viewModel.context.activeProfile?.name ?? "Profile" }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.entries.isEmpty {
                VStack(spacing: HopSpacing.sm) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(HopOverlay.tertiaryText)
                    Text("Nothing to switch to")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(HopOverlay.secondaryText)
                    Text("Open an app, or pin apps in Settings")
                        .font(.system(size: 11))
                        .foregroundStyle(HopOverlay.tertiaryText)
                }
                .padding(.horizontal, HopSpacing.xxl)
                .padding(.vertical, HopSpacing.xl)
            } else {
                VStack(alignment: .leading, spacing: HopSpacing.sm) {
                    if !pinnedIndices.isEmpty {
                        group(title: activeProfileName.uppercased(), indices: pinnedIndices)
                    }
                    if !otherIndices.isEmpty {
                        if !pinnedIndices.isEmpty {
                            Divider().overlay(HopOverlay.tertiaryText.opacity(0.4))
                        }
                        group(title: "OTHER RUNNING", indices: otherIndices)
                    }
                }
                .animation(HopMotion.snappy, value: viewModel.selectedIndex)
                .animation(HopMotion.snappy, value: viewModel.entries)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("App Switcher")
                // Keep the panel at least as wide as the name line's cap so
                // selection changes never resize the panel.
                .frame(minWidth: 320)
                .padding(.horizontal, HopSpacing.lg)
                .padding(.top, HopSpacing.md)

                Text(selectedAppName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(HopOverlay.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 320)
                    .padding(.top, HopSpacing.sm)
                    .accessibilityHidden(true)

                footer
                    .padding(.top, HopSpacing.xs)
                    .padding(.bottom, viewModel.showHints ? HopSpacing.sm : HopSpacing.md)

                if viewModel.showHints {
                    HStack(spacing: HopSpacing.lg) {
                        HintLabel(text: "Tab to cycle")
                        HintLabel(text: "Release to switch")
                        HintLabel(text: "Esc to cancel")
                    }
                    .padding(.bottom, HopSpacing.md)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
        }
        .animation(HopMotion.panel, value: viewModel.showHints)
        // Never wider than the target screen's visible frame minus a margin.
        .frame(maxWidth: viewModel.maxContentWidth)
        .overlaySurface()
    }

    @ViewBuilder
    private func group(title: String, indices: [Int]) -> some View {
        VStack(alignment: .leading, spacing: HopSpacing.xs) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(HopOverlay.tertiaryText)
                .padding(.leading, HopSpacing.sm)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: HopSpacing.xs) {
                ForEach(rows(indices), id: \.self) { row in
                    HStack(spacing: HopSpacing.xs) {
                        ForEach(row, id: \.self) { index in
                            appButton(at: index)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func appButton(at index: Int) -> some View {
        let app = viewModel.entries[index].app
        let isSelected = index == viewModel.selectedIndex

        Button {
            viewModel.onAppClicked?(index)
        } label: {
            AppIconView(app: app, isSelected: isSelected, iconSize: layout.iconSize)
                .padding(HopSpacing.md)
                .background {
                    // Native Cmd+Tab-style backplate that slides between
                    // icons — across rows too — instead of a stroke + scale.
                    if isSelected {
                        RoundedRectangle(cornerRadius: HopRadius.card + 6, style: .continuous)
                            .fill(HopOverlay.backplate)
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .matchedGeometryEffect(id: app.bundleIdentifier, in: selection)
        .accessibilityLabel("\(app.displayName), \(app.isRunning ? "running" : "not running")")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var selectedAppName: String {
        guard viewModel.entries.indices.contains(viewModel.selectedIndex) else { return " " }
        let app = viewModel.entries[viewModel.selectedIndex].app
        return app.isRunning ? app.displayName : "\(app.displayName) — not running"
    }

    // MARK: Footer — pin hint

    /// What a keypress would do to the highlighted app, plus the digit map
    /// when more than one profile exists.
    @ViewBuilder
    private var footer: some View {
        let ctx = viewModel.context
        if let feedback = viewModel.feedback {
            HStack(spacing: HopSpacing.xs) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(HopColor.success)
                Text(feedback)
                    .foregroundStyle(HopOverlay.primaryText)
            }
            .font(.system(size: 11, weight: .medium))
            .transition(.opacity)
        } else if viewModel.entries.indices.contains(viewModel.selectedIndex), ctx.activeProfile != nil {
            let entry = viewModel.entries[viewModel.selectedIndex]
            VStack(spacing: HopSpacing.xs) {
                HStack(spacing: HopSpacing.md) {
                    HStack(spacing: HopSpacing.xs) {
                        KeyBadge(entry.isPinned ? "⌫" : "P")
                        // Both phrases are laid out so the footer, and with
                        // it the panel, keeps one width while cycling.
                        ZStack(alignment: .leading) {
                            Text("unpin from \(activeProfileName)").hidden()
                            Text("pin to \(activeProfileName)").hidden()
                            Text(entry.isPinned ? "unpin from \(activeProfileName)" : "pin to \(activeProfileName)")
                        }
                        .foregroundStyle(HopOverlay.secondaryText)
                    }
                    if ctx.canAddWorkspace {
                        HStack(spacing: HopSpacing.xs) {
                            KeyBadge("N")
                            Text("new workspace")
                                .foregroundStyle(HopOverlay.secondaryText)
                        }
                    }
                }
                if ctx.slots.count > 1 {
                    HStack(spacing: HopSpacing.sm) {
                        ForEach(Array(ctx.slots.enumerated()), id: \.element.id) { slot, profile in
                            let member = ctx.isPinned(entry.app.bundleIdentifier, in: profile)
                            HStack(spacing: 3) {
                                KeyBadge("\(slot + 1)")
                                Text(profile.name)
                                    .foregroundStyle(member ? HopOverlay.primaryText : HopOverlay.tertiaryText)
                                // Always laid out; only visible when the app
                                // is in this workspace. Keeps the row width
                                // constant as the highlight moves.
                                Image(systemName: "checkmark")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(HopColor.success)
                                    .opacity(member ? 1 : 0)
                            }
                        }
                    }
                    .lineLimit(1)
                }
            }
            .font(.system(size: 11))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(entry.isPinned
                ? "Press Delete to remove \(entry.app.displayName) from \(activeProfileName)"
                : "Press P to pin \(entry.app.displayName) to \(activeProfileName)")
        }
    }
}

/// A small key cap used in overlay hints.
private struct KeyBadge: View {
    let label: String
    init(_ label: String) { self.label = label }

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(HopOverlay.primaryText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(HopOverlay.backplate)
            )
    }
}

private struct HintLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(HopOverlay.secondaryText)
    }
}

// MARK: - Profile Overlay View

struct ProfileOverlayView: View {
    @ObservedObject var viewModel: ProfileOverlayViewModel
    @Namespace private var selection

    var body: some View {
        HStack(spacing: HopSpacing.sm) {
            ForEach(Array(viewModel.profiles.enumerated()), id: \.element.id) { index, profile in
                let isSelected = index == viewModel.selectedIndex
                VStack(spacing: 6) {
                    ProfileAppIcons(apps: profile.pinnedApps, isSelected: isSelected)

                    Text(profile.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? HopOverlay.primaryText : HopOverlay.secondaryText)
                        .lineLimit(1)
                }
                .padding(.horizontal, HopSpacing.md)
                .padding(.vertical, HopSpacing.sm + 2)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                            .fill(HopOverlay.backplate)
                            .matchedGeometryEffect(id: "selection", in: selection)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(profile.name)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(HopMotion.snappy, value: viewModel.selectedIndex)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Profile Switcher")
        .padding(.horizontal, HopSpacing.lg)
        .padding(.vertical, HopSpacing.lg)
        .overlaySurface()
    }
}

// MARK: - Profile App Icons

/// Shows a small grid of pinned app icons for a profile (up to 4 in a 2x2 grid).
private struct ProfileAppIcons: View {
    let apps: [PinnedApp]
    let isSelected: Bool

    private let iconSize: CGFloat = 16
    private let gridSpacing: CGFloat = 3

    var body: some View {
        let visible = Array(apps.prefix(4))
        let remaining = apps.count - visible.count

        ZStack {
            if visible.isEmpty {
                Image(systemName: "square.dashed")
                    .font(.system(size: 24))
                    .foregroundStyle(isSelected ? HopOverlay.secondaryText : HopOverlay.tertiaryText)
            } else {
                let columns = visible.count <= 1 ? 1 : 2
                let gridCols = Array(repeating: GridItem(.fixed(iconSize), spacing: gridSpacing), count: columns)

                LazyVGrid(columns: gridCols, spacing: gridSpacing) {
                    ForEach(visible) { app in
                        Image(nsImage: app.icon)
                            .resizable()
                            .frame(width: iconSize, height: iconSize)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if remaining > 0 {
                        Text("+\(remaining)")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(HopOverlay.primaryText)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.black.opacity(0.6)))
                            .offset(x: 4, y: 4)
                    }
                }
            }
        }
        .frame(width: 40, height: 40)
        .accessibilityHidden(true)
    }
}

// MARK: - Window Picker View

struct WindowPickerView: View {
    @ObservedObject var viewModel: WindowPickerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: app icon + name
            HStack(spacing: 10) {
                Image(nsImage: viewModel.appIcon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .accessibilityHidden(true)
                Text(viewModel.appName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HopOverlay.primaryText)
            }
            .padding(.horizontal, HopSpacing.lg)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, HopSpacing.md)

            // Window list
            VStack(spacing: 2) {
                ForEach(Array(viewModel.windows.enumerated()), id: \.element.id) { index, window in
                    let isSelected = index == viewModel.selectedIndex
                    HStack(spacing: HopSpacing.sm) {
                        Image(systemName: window.isMinimized ? "minus.circle" : "macwindow")
                            .font(.system(size: 13))
                            .foregroundStyle(isSelected ? HopOverlay.primaryText : HopOverlay.secondaryText)
                            .frame(width: 16)

                        Text(window.title)
                            .font(.system(size: 13))
                            .foregroundStyle(HopOverlay.primaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HopSpacing.md)
                    .padding(.vertical, HopSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(window.title)\(window.isMinimized ? ", minimized" : "")")
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .animation(HopMotion.snappy, value: viewModel.selectedIndex)
            .padding(.horizontal, HopSpacing.sm)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Windows")
        }
        .frame(width: 320)
        .overlaySurface()
    }
}

// MARK: - Sticky Note Overlay View

struct StickyNoteOverlayView: View {
    let profileName: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: HopSpacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .foregroundStyle(HopOverlay.secondaryText)
                    .accessibilityHidden(true)
                Text(profileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HopOverlay.primaryText)
            }

            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(HopOverlay.primaryText)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(HopSpacing.lg)
        .frame(maxWidth: 320, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(profileName) note. \(note)")
        .overlaySurface()
    }
}

// MARK: - Toast Overlay View

struct ToastOverlayView: View {
    let icon: String
    let message: String

    var body: some View {
        HStack(spacing: HopSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(HopOverlay.primaryText)
                .accessibilityHidden(true)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HopOverlay.primaryText)
        }
        .padding(.horizontal, HopSpacing.xl - 4)
        .padding(.vertical, HopSpacing.md)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .overlaySurface()
    }
}

// MARK: - Visual Effect (NSVisualEffectView wrapper)

struct VisualEffectBlur: NSViewRepresentable {
    var cornerRadius: CGFloat = 0

    private static var maskCache: [CGFloat: NSImage] = [:]

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = Self.cachedMaskImage(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    private static func cachedMaskImage(cornerRadius: CGFloat) -> NSImage {
        if let cached = maskCache[cornerRadius] { return cached }

        let edgeLength = 2.0 * cornerRadius + 1.0
        let image = NSImage(size: NSSize(width: edgeLength, height: edgeLength), flipped: false) { rect in
            let bezierPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.set()
            bezierPath.fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        image.resizingMode = .stretch
        maskCache[cornerRadius] = image
        return image
    }
}
