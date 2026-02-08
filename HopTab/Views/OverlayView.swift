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
            VisualEffectBlur()
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .shadow(color: .black.opacity(0.3), radius: 20, y: 5)
    }
}

// MARK: - Visual Effect (NSVisualEffectView wrapper)

struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
