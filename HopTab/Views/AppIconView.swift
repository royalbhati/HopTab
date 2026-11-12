import SwiftUI

struct AppIconView: View {
    let app: PinnedApp
    let isSelected: Bool
    var iconSize: CGFloat = 64

    var body: some View {
        // One running-apps lookup per render, not four.
        let isRunning = app.isRunning
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .saturation(isRunning ? 1.0 : 0.4)
                .opacity(isRunning ? 1.0 : 0.6)

            // Running indicator — Dock-style: shown only when running, since
            // desaturation already marks the not-running state.
            if isRunning {
                Circle()
                    .fill(Color.green)
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(Color.black.opacity(0.3), lineWidth: 0.5))
                    .offset(x: -3, y: -3)
            }
        }
        .accessibilityLabel("\(app.displayName), \(isRunning ? "running" : "not running")")
    }
}
