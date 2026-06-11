import SwiftUI

struct AppIconView: View {
    let app: PinnedApp
    let isSelected: Bool
    var iconSize: CGFloat = 64

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .saturation(app.isRunning ? 1.0 : 0.4)
                .opacity(app.isRunning ? 1.0 : 0.6)

            // Running indicator — Dock-style: shown only when running, since
            // desaturation already marks the not-running state.
            if app.isRunning {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
                    .offset(x: -3, y: -3)
            }
        }
        .accessibilityLabel("\(app.displayName), \(app.isRunning ? "running" : "not running")")
    }
}
