import SwiftUI

struct OverlayView: View {
    let apps: [PinnedApp]
    let selectedIndex: Int

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                AppIconView(app: app, isSelected: index == selectedIndex)
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

// MARK: - Profile Overlay View

struct ProfileOverlayView: View {
    let profiles: [Profile]
    let selectedIndex: Int

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                let isSelected = index == selectedIndex
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
    let appName: String
    let appIcon: NSImage
    let windows: [WindowInfo]
    let selectedIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: app icon + name
            HStack(spacing: 10) {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 32, height: 32)
                Text(appName)
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
                ForEach(Array(windows.enumerated()), id: \.element.id) { index, window in
                    let isSelected = index == selectedIndex
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

// MARK: - Visual Effect (NSVisualEffectView wrapper)

struct VisualEffectBlur: NSViewRepresentable {
    var cornerRadius: CGFloat = 0

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        view.maskImage = maskImage(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}

    private func maskImage(cornerRadius: CGFloat) -> NSImage {
        let edgeLength = 2.0 * cornerRadius + 1.0
        let maskImage = NSImage(size: NSSize(width: edgeLength, height: edgeLength), flipped: false) { rect in
            let bezierPath = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.set()
            bezierPath.fill()
            return true
        }
        maskImage.capInsets = NSEdgeInsets(top: cornerRadius, left: cornerRadius, bottom: cornerRadius, right: cornerRadius)
        maskImage.resizingMode = .stretch
        return maskImage
    }
}
