import SwiftUI

struct AppIconView: View {
    let app: PinnedApp
    let isSelected: Bool

    private let iconSize: CGFloat = 64
    private let totalSize: CGFloat = 90

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconSize, height: iconSize)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 3)
                        .animation(.easeInOut(duration: 0.15), value: isSelected)
                )
                .scaleEffect(isSelected ? 1.1 : 1.0)
                .animation(.easeInOut(duration: 0.15), value: isSelected)

            Text(app.displayName)
                .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .frame(width: totalSize)
        }
        .frame(width: totalSize)
        .opacity(app.isRunning ? 1.0 : 0.5)
    }
}
