import SwiftUI

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel
    @Namespace private var selection

    /// Shrink icons when many apps are pinned so the row stays on screen.
    private var iconSize: CGFloat { viewModel.apps.count > 12 ? 48 : 64 }

    var body: some View {
        VStack(spacing: 0) {
            if viewModel.apps.isEmpty {
                VStack(spacing: HopSpacing.sm) {
                    Image(systemName: "square.dashed")
                        .font(.system(size: 28))
                        .foregroundStyle(HopOverlay.tertiaryText)
                    Text("No pinned apps")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(HopOverlay.secondaryText)
                    Text("Pin apps in Settings to switch between them")
                        .font(.system(size: 11))
                        .foregroundStyle(HopOverlay.tertiaryText)
                }
                .padding(.horizontal, HopSpacing.xxl)
                .padding(.vertical, HopSpacing.xl)
            } else {
                HStack(spacing: HopSpacing.xs) {
                    ForEach(Array(viewModel.apps.enumerated()), id: \.element.id) { index, app in
                        AppIconView(app: app, isSelected: index == viewModel.selectedIndex, iconSize: iconSize)
                            .padding(HopSpacing.md)
                            .background {
                                // Native Cmd+Tab-style backplate that slides
                                // between icons instead of a stroke + scale.
                                if index == viewModel.selectedIndex {
                                    RoundedRectangle(cornerRadius: HopRadius.card + 6, style: .continuous)
                                        .fill(HopOverlay.backplate)
                                        .matchedGeometryEffect(id: "selection", in: selection)
                                }
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { viewModel.onAppClicked?(index) }
                            .accessibilityAddTraits(index == viewModel.selectedIndex ? .isSelected : [])
                    }
                }
                .animation(.snappy(duration: 0.18), value: viewModel.selectedIndex)
                .accessibilityLabel("App Switcher")
                // Keep the panel at least as wide as the name line's cap so
                // selection changes never resize the panel.
                .frame(minWidth: 260)
                .padding(.horizontal, HopSpacing.lg)
                .padding(.top, HopSpacing.lg)

                Text(selectedAppName)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(HopOverlay.primaryText)
                    .lineLimit(1)
                    .frame(maxWidth: 240)
                    .padding(.top, HopSpacing.sm)
                    .padding(.bottom, viewModel.showHints ? HopSpacing.sm : HopSpacing.lg)

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
        .overlayChrome()
    }

    private var selectedAppName: String {
        guard viewModel.apps.indices.contains(viewModel.selectedIndex) else { return " " }
        let app = viewModel.apps[viewModel.selectedIndex]
        return app.isRunning ? app.displayName : "\(app.displayName) — not running"
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
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .animation(.snappy(duration: 0.18), value: viewModel.selectedIndex)
        .padding(.horizontal, HopSpacing.lg)
        .padding(.vertical, HopSpacing.lg)
        .overlayChrome()
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
                    .accessibilityLabel("\(window.title)\(window.isMinimized ? ", minimized" : "")")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HopSpacing.md)
                    .padding(.vertical, HopSpacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                }
            }
            .padding(.horizontal, HopSpacing.sm)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .frame(width: 320)
        .overlayChrome()
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
        .overlayChrome()
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
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(HopOverlay.primaryText)
        }
        .padding(.horizontal, HopSpacing.xl - 4)
        .padding(.vertical, HopSpacing.md)
        .overlayChrome()
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
