import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Pro Section

struct ProSection: View {
    @ObservedObject private var nav = SettingsNavigation.shared

    private var isLicensed: Bool { ProServiceRegistry.shared.isLicensed }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: HopSpacing.sm) {
                HStack(spacing: HopSpacing.sm + 2) {
                    Image(systemName: "star.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(HopColor.pro)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HopTab Pro")
                            .font(.title3.weight(.bold))
                        Text("HopTab switches your workspace for you \u{2014} from your calendar, the clock, a Focus mode or the monitor you plug in.")
                            .font(.hopSubheading)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if isLicensed {
                    HStack(spacing: HopSpacing.xs + 2) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(HopColor.success)
                            .accessibilityHidden(true)
                        Text("Pro Active")
                            .font(.hopSubheading.weight(.medium))
                            .foregroundStyle(HopColor.success)
                    }
                    .padding(.top, HopSpacing.xs)
                } else {
                    Link(destination: ProLinks.purchaseURL) {
                        Text("Unlock Pro \u{2014} $5 one-time")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .padding(.top, HopSpacing.xs)

                    Link(destination: URL(string: "https://github.com/sponsors/royalbhati")!) {
                        Text("or sponsor on GitHub")
                            .font(.hopCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        ProLicenseSection()

        Section("What Pro includes") {
            ForEach(ProSection.features) { feature in
                proFeature(feature)
            }
        }

        Section {
            HopBanner(
                icon: ProLabs.systemImage,
                tone: HopColor.warning,
                title: ProLabs.title,
                detail: ProLabs.warning
            ) {
                EmptyView()
            }
            ForEach(ProSection.labsFeatures) { feature in
                proFeature(feature)
            }
        } header: {
            Label(ProLabs.title, systemImage: ProLabs.systemImage)
        } footer: {
            Text("Labs features are included with Pro, but they are not finished. All of them are off until you turn them on.")
        }


        if !isLicensed {
            Section {
                VStack(alignment: .leading, spacing: HopSpacing.xs) {
                    Text("Can't afford it?")
                        .font(.hopSubheading.weight(.medium))
                    Text("If you're a student or really think these features can make your life better but can't afford $5 \u{2014} send me an email and I'll give you Pro for free. No questions asked.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("rawyelll@gmail.com", destination: URL(string: "mailto:rawyelll@gmail.com?subject=HopTab%20Pro%20Request")!)
                        .font(.hopCaption)
                }
            }
        }
    }

    // MARK: Feature list

    fileprivate struct ProFeature: Identifiable {
        let id: String
        let icon: String
        let color: Color
        let title: String
        let description: String
    }

    /// Kept accurate on purpose.
    fileprivate static let features: [ProFeature] = [
        .init(id: "calendar", icon: "calendar", color: .red,
              title: "Calendar Auto-Switch",
              description: "\u{201C}Daily Standup\u{201D} starts \u{2192} switches to your Meeting profile. Detects Zoom, Teams and Meet links, with a Join button."),
        .init(id: "schedule", icon: "clock.badge", color: .orange,
              title: "Time Schedule",
              description: "\u{201C}At 7 PM switch to Entertainment.\u{201D} Set it once, filter by weekday, runs every day."),
        .init(id: "focus-mode", icon: "moon.fill", color: .purple,
              title: "Focus Mode Integration",
              description: "Enable the \u{201C}Work\u{201D} Focus \u{2192} auto-switches to your Work profile. Multiple profiles per Focus mode."),
        .init(id: "displays", icon: "display", color: .cyan,
              title: "Display Auto-Profiles",
              description: "Plug in your external monitor \u{2192} \u{201C}Docked\u{201D} profile. Unplug \u{2192} \u{201C}Laptop\u{201D}."),
        .init(id: "rules", icon: "rectangle.badge.plus", color: .green,
              title: "Window Rules",
              description: "\u{201C}VS Code always left 60%\u{201D} \u{2014} set once, auto-snaps on every launch or focus. The free tier gets \(ProFeatureGate.freeWindowRuleLimit)."),
        .init(id: "layouts", icon: "rectangle.3.group.fill", color: .yellow,
              title: "Custom Layouts",
              description: "Build layouts with exact width and height percentages \u{2014} any arrangement you want."),
        .init(id: "profiles", icon: "square.stack.3d.up.fill", color: .indigo,
              title: "Unlimited Profiles",
              description: "The free tier allows \(ProFeatureGate.freeProfileLimit) profiles. Pro removes the limit."),
        .init(id: "undo", icon: "arrow.uturn.backward", color: .brown,
              title: "Window Undo",
              description: "Undo and redo any window move or resize \u{2014} step back through your recent window operations."),
        .init(id: "time", icon: "chart.bar.xaxis", color: .blue,
              title: "Time Tracking",
              description: "See how long you spend in each workspace, with per-app breakdowns and daily limits."),
        .init(id: "breaks", icon: "cup.and.saucer.fill", color: .mint,
              title: "Screen Breaks",
              description: "Break reminders with a countdown screen; windows go back where they were."),
        .init(id: "pomodoro", icon: "timer", color: .pink,
              title: "Pomodoro & Focus Sessions",
              description: "Work/break intervals tied to a calendar event, or a timed session scoped to one workspace."),
    ]

    /// Included with Pro, but experimental or off the core path — these ship
    /// off and are listed separately so nothing here reads as the product.
    fileprivate static let labsFeatures: [ProFeature] = [
        .init(id: "bsp", icon: "rectangle.split.2x2", color: .blue,
              title: "Auto-tiling (BSP)",
              description: "Every new window is tiled into the free space automatically, yabai-style."),
    ]

    private func proFeature(_ feature: ProFeature) -> some View {
        HStack(alignment: .top, spacing: HopSpacing.md) {
            Image(systemName: feature.icon)
                .font(.hopSubheading)
                .foregroundStyle(feature.color)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                        .fill(feature.color.opacity(0.12))
                )
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title)
                    .font(.hopSubheading.weight(.semibold))
                Text(feature.description)
                    .font(.hopCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - License

/// License entry — the destination for every "I have a key" affordance.
struct ProLicenseSection: View {
    @ObservedObject private var nav = SettingsNavigation.shared

    var body: some View {
        if let provider = ProServiceRegistry.shared.provider {
            Section {
                provider.licenseSectionView()
            } header: {
                Text("License")
            } footer: {
                Text("Paste the key from your purchase email. It activates this Mac; you can move it to another Mac later.")
            }
            .background(
                RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                    .stroke(
                        nav.focusedDestination == .pro ? Color.accentColor.opacity(0.5) : Color.clear,
                        lineWidth: 2
                    )
                    .animation(HopMotion.snappy, value: nav.focusedDestination)
            )
            .task(id: nav.focusedDestination) {
                // The deep-link highlight is a hint, not a permanent state.
                guard nav.focusedDestination == .pro else { return }
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                guard !Task.isCancelled else { return }
                nav.focusedDestination = nil
            }
        }

    }
}
