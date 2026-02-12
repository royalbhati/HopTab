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
