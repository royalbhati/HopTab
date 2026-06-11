import SwiftUI

// MARK: - Design Tokens
//
// Shared visual constants for HopTab. Use these instead of ad-hoc values so
// spacing, radii, and overlay colors stay consistent across views.

/// 4-pt spacing grid.
enum HopSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Corner radius scale.
enum HopRadius {
    /// Small controls: chips, badges, shortcut recorders.
    static let control: CGFloat = 6
    /// Cards, banners, template tiles.
    static let card: CGFloat = 10
    /// Floating overlay panels (switcher, picker, toast, sticky note).
    static let panel: CGFloat = 20
}

/// Foreground levels and surfaces for HUD overlays. The `.hudWindow`
/// material is dark in both light and dark appearance, so overlay text is
/// always white-based — never `.primary`, which flips in light mode.
enum HopOverlay {
    static let primaryText = Color.white
    static let secondaryText = Color.white.opacity(0.65)
    static let tertiaryText = Color.white.opacity(0.45)
    /// Selection backplate behind icons (native Cmd+Tab style).
    static let backplate = Color.white.opacity(0.18)
    static let shadowColor = Color.black.opacity(0.3)
    static let shadowRadius: CGFloat = 20
    static let shadowY: CGFloat = 5
}

// MARK: - Overlay container

/// Standard chrome for every floating overlay: HUD blur, continuous
/// rounded corners at the panel radius, soft shadow.
struct OverlayChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background { VisualEffectBlur(cornerRadius: HopRadius.panel) }
            .clipShape(RoundedRectangle(cornerRadius: HopRadius.panel, style: .continuous))
            .shadow(color: HopOverlay.shadowColor, radius: HopOverlay.shadowRadius, y: HopOverlay.shadowY)
    }
}

extension View {
    func overlayChrome() -> some View { modifier(OverlayChrome()) }
}
