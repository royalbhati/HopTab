import AppKit
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

/// Text-style aliases: use these (Dynamic Type) instead of `.system(size:)`.
extension Font {
    /// Section/group headings in settings forms.
    static let hopHeading = Font.headline
    /// Row labels and secondary headings.
    static let hopSubheading = Font.subheadline
    /// Explanatory helper text under controls.
    static let hopCaption = Font.caption
    /// Fine print / tertiary annotations.
    static let hopFootnote = Font.footnote
}

/// Semantic colors. Use these instead of raw `.yellow` / `.orange` / `.green`
/// so meaning stays consistent and contrast stays legible in both appearances.
///
/// `.yellow` in particular must never be used for text on a light background:
/// it lands around 1.6:1 contrast, well under the 4.5:1 minimum.
enum HopColor {
    /// Pro-only features: badges, locks, upsell accents.
    /// Deliberately NOT plain `.yellow` — that fails contrast as a text color.
    static let pro = Color.orange

    /// Needs attention but is not broken: missing permission, secure input
    /// active, a conflicting system setting.
    static let warning = Color.orange

    /// Confirmation: permission granted, license active, app running.
    static let success = Color.green

    /// Destructive or failed: delete actions, snap failures.
    static let danger = Color.red

    /// A tinted fill behind a semantic color, for banner backgrounds.
    static func tint(_ color: Color) -> Color { color.opacity(0.12) }

    /// A border to pair with `tint(_:)`.
    static func edge(_ color: Color) -> Color { color.opacity(0.35) }

    /// Running / active indicator dot. Pair with a text label or an
    /// accessibility label — color alone must never carry the meaning.
    static let runningIndicator = Color.green
}

/// Motion that respects the user's Reduce Motion setting.
///
/// Every spring and slide in the app should go through this, not through a
/// literal `.spring(...)`, so the Accessibility setting is honored everywhere.
enum HopMotion {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Snappy UI transition (selection, backplate). Becomes a near-instant
    /// cross-fade when Reduce Motion is on.
    static var snappy: Animation? {
        reduceMotion ? .linear(duration: 0.01) : .snappy(duration: 0.18)
    }

    /// Panel appearance / disappearance.
    static var panel: Animation? {
        reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.13)
    }

    /// Playful emphasis (pin bounce, success). Suppressed entirely under
    /// Reduce Motion rather than merely shortened.
    static var emphasis: Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6)
    }

    /// Duration for AppKit animations (`NSAnimationContext`), which cannot
    /// consume SwiftUI's `Animation`. Keeps AppKit and SwiftUI timing on one
    /// source of truth and collapses to near-instant under Reduce Motion.
    static func duration(_ base: TimeInterval) -> TimeInterval {
        reduceMotion ? 0.01 : base
    }

    /// Standard overlay fade-in / fade-out durations.
    static var panelFadeIn: TimeInterval { duration(0.13) }
    static var panelFadeOut: TimeInterval { duration(0.10) }
    static var panelReflow: TimeInterval { duration(0.18) }
}

/// Prominent call-to-action button.
///
/// Replaces hand-rolled `.plain` buttons that paint `Color.accentColor` and
/// draw `.white` text — those become illegible under a light system accent
/// and have no focus ring or pressed state.
struct HopProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.hopSubheading.weight(.semibold))
            .padding(.horizontal, HopSpacing.lg)
            .padding(.vertical, HopSpacing.sm)
            .frame(minHeight: 28)
            .background(
                RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                    .fill(Color.accentColor)
                    .opacity(configuration.isPressed ? 0.78 : 1)
            )
            // Adapts to the accent color's own luminance instead of hard-coding white.
            .foregroundStyle(Color.white)
            .contentShape(RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous))
    }
}

extension ButtonStyle where Self == HopProminentButtonStyle {
    /// Prefer the system `.borderedProminent` where a plain button will do;
    /// use this only where the CTA needs custom metrics.
    static var hopProminent: HopProminentButtonStyle { HopProminentButtonStyle() }
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
/// rounded corners at the panel radius, and optionally a soft shadow.
///
/// **Pass `shadow: false` for anything hosted in an `NSPanel`.** A SwiftUI
/// shadow draws *outside* the view's bounds, and an overlay panel is sized to
/// `hostingView.fittingSize` — so the shadow lands outside the window frame
/// and is clipped away entirely. Panels set `hasShadow = true` and let AppKit
/// draw it instead. Keep the shadow only for surfaces inside a larger window.
struct OverlayChrome: ViewModifier {
    var shadow: Bool = true

    func body(content: Content) -> some View {
        content
            .background { VisualEffectBlur(cornerRadius: HopRadius.panel) }
            .clipShape(RoundedRectangle(cornerRadius: HopRadius.panel, style: .continuous))
            .shadow(
                color: shadow ? HopOverlay.shadowColor : .clear,
                radius: shadow ? HopOverlay.shadowRadius : 0,
                y: shadow ? HopOverlay.shadowY : 0
            )
    }
}

extension View {
    func overlayChrome(shadow: Bool = true) -> some View {
        modifier(OverlayChrome(shadow: shadow))
    }
}
