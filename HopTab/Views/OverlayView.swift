import SwiftUI

struct OverlayView: View {
    @ObservedObject var viewModel: OverlayViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ForEach(Array(viewModel.apps.enumerated()), id: \.element.id) { index, app in
                    AppIconView(app: app, isSelected: index == viewModel.selectedIndex)
                        .contentShape(Rectangle())
                        .onTapGesture { viewModel.onAppClicked?(index) }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, viewModel.showHints ? 8 : 16)

            if viewModel.showHints {
                HStack(spacing: 16) {
                    HintLabel(text: "Tab to cycle")
                    HintLabel(text: "Release to switch")
                    HintLabel(text: "Esc to cancel")
                }
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .background {
            VisualEffectBlur(cornerRadius: 18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 5)
    }
}

private struct HintLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.5))
    }
}

// MARK: - Profile Overlay View

struct ProfileOverlayView: View {
    @ObservedObject var viewModel: ProfileOverlayViewModel

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(viewModel.profiles.enumerated()), id: \.element.id) { index, profile in
                let isSelected = index == viewModel.selectedIndex
                VStack(spacing: 4) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(isSelected ? .white : .secondary)

                    Text(profile.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : .primary)
                        .lineLimit(1)

                    Text("\(profile.pinnedApps.count) app\(profile.pinnedApps.count == 1 ? "" : "s")")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? .white.opacity(0.7) : .secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(isSelected ? Color.accentColor : Color.clear)
                )
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background {
            VisualEffectBlur(cornerRadius: 18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 5)
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
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider()
                .padding(.horizontal, 12)

            // Window list
            VStack(spacing: 2) {
                ForEach(Array(viewModel.windows.enumerated()), id: \.element.id) { index, window in
                    let isSelected = index == viewModel.selectedIndex
                    HStack(spacing: 8) {
                        Image(systemName: window.isMinimized ? "minus.circle" : "macwindow")
                            .font(.system(size: 13))
                            .foregroundStyle(isSelected ? .white : .secondary)
                            .frame(width: 16)

                        Text(window.title)
                            .font(.system(size: 13))
                            .foregroundStyle(isSelected ? .white : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(isSelected ? Color.accentColor : Color.clear)
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 10)
        }
        .frame(width: 320)
        .background {
            VisualEffectBlur(cornerRadius: 18)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 5)
    }
}

// MARK: - Sticky Note Overlay View

struct StickyNoteOverlayView: View {
    let profileName: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "note.text")
                    .foregroundStyle(.secondary)
                Text(profileName)
                    .font(.system(size: 13, weight: .semibold))
            }

            Text(note)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .lineLimit(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: 320, alignment: .leading)
        .background {
            VisualEffectBlur(cornerRadius: 14)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 5)
    }
}

// MARK: - Toast Overlay View

struct ToastOverlayView: View {
    let icon: String
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(.white)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background {
            VisualEffectBlur(cornerRadius: 12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 5)
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
