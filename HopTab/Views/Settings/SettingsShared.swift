import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shared UI

/// A semantic banner: icon, headline, optional detail, optional trailing action.
/// Replaces the five hand-rolled orange `HStack`s this file used to carry.
struct HopBanner<Action: View>: View {
    let icon: String
    let tone: Color
    let title: String
    var detail: String?
    @ViewBuilder var action: () -> Action

    var body: some View {
        HStack(alignment: .top, spacing: HopSpacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tone)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.hopSubheading.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: HopSpacing.sm)
            action()
        }
        .padding(HopSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                .fill(HopColor.tint(tone))
                .overlay(
                    RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                        .stroke(HopColor.edge(tone), lineWidth: 1)
                )
        )
    }
}

/// Honest locked state for a Pro feature: readable description, one explicit
/// unlock button. Never a real config view dimmed to 40% behind an invisible
/// full-card tap target.
struct ProLockedCard: View {
    let title: String
    let description: String
    var systemImage: String = "lock.fill"

    var body: some View {
        VStack(alignment: .leading, spacing: HopSpacing.sm) {
            HStack(spacing: HopSpacing.sm) {
                Image(systemName: systemImage)
                    .foregroundStyle(HopColor.pro)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.hopHeading)
                Text("PRO")
                    .font(.hopFootnote.weight(.bold))
                    .foregroundStyle(HopColor.pro)
                    .padding(.horizontal, HopSpacing.xs + 2)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(HopColor.tint(HopColor.pro))
                    )
                    .accessibilityLabel("Pro feature")
                Spacer(minLength: 0)
            }

            Text(description)
                .font(.hopCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: HopSpacing.md) {
                Link(destination: ProLinks.purchaseURL) {
                    Text("Unlock \u{2014} $5")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

                Button("I have a key") {
                    SettingsNavigation.open(.pro)
                }
                .controlSize(.small)
            }
        }
        .padding(.vertical, HopSpacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The Labs group, rendered from `ProSectionDescriptor.isLabs`.
///
/// Every experimental Pro card in Settings goes through here, so the
/// `ProLabs.warning` copy is shown exactly once per group and an experimental
/// feature can never end up sitting next to a stable one.
struct ProLabsGroup: View {
    var placement: ProSectionPlacement?

    private var descriptors: [ProSectionDescriptor] {
        ProServiceRegistry.shared.provider?.labsSectionViews(in: placement) ?? []
    }

    var body: some View {
        if !descriptors.isEmpty {
            Section {
                HopBanner(
                    icon: ProLabs.systemImage,
                    tone: HopColor.warning,
                    title: ProLabs.title,
                    detail: ProLabs.warning
                ) {
                    EmptyView()
                }

                ForEach(descriptors) { descriptor in
                    DisclosureGroup {
                        descriptor.view
                            .padding(.top, HopSpacing.xs)
                    } label: {
                        Label(descriptor.title, systemImage: descriptor.systemImage)
                            .font(.hopSubheading)
                    }
                }
            } header: {
                Label(ProLabs.title, systemImage: ProLabs.systemImage)
            }
        }
    }
}

/// Non-experimental Pro cards for one part of Settings, from
/// `ProSectionDescriptor.isLabs == false`. Rendered inline (no Labs warning).
struct ProStableGroup: View {
    var placement: ProSectionPlacement?

    private var descriptors: [ProSectionDescriptor] {
        ProServiceRegistry.shared.provider?.stableSectionViews(in: placement) ?? []
    }

    var body: some View {
        ForEach(descriptors) { descriptor in
            Section {
                descriptor.view
            } header: {
                Label(descriptor.title, systemImage: descriptor.systemImage)
            }
        }
    }
}

/// Window Undo — stable Pro feature, lives with the other window actions.
struct WindowActionsSection: View {
    var body: some View {
        if ProServiceRegistry.shared.isLicensed {
            ProStableGroup(placement: .windows)
        } else {
            Section {
                ProLockedCard(
                    title: "Window Undo",
                    description: "Undo and redo any window move or resize \u{2014} step back through your recent window operations, including the ones HopTab made for you.",
                    systemImage: "arrow.uturn.backward"
                )
            }
        }
    }
}

/// Showcase header at the top of a feature pane: a big tinted glyph, a
/// one-line promise, a short explanation, and the steps that make it work.
/// The same view renders for free and Pro users — the config below it is
/// what changes.
struct FeatureHero: View {
    let icon: String
    let tint: Color
    let title: String
    let tagline: String
    let detail: String
    var steps: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: HopSpacing.md) {
            HStack(alignment: .top, spacing: HopSpacing.lg) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(HopColor.tint(tint))
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: HopSpacing.xs) {
                    Text(title)
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)
                    Text(tagline)
                        .font(.hopSubheading.weight(.medium))
                        .foregroundStyle(tint)
                    Text(detail)
                        .font(.hopSubheading)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }

            if !steps.isEmpty {
                HStack(alignment: .top, spacing: HopSpacing.sm) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(alignment: .top, spacing: HopSpacing.sm) {
                            Text("\(index + 1)")
                                .font(.hopCaption.weight(.bold).monospacedDigit())
                                .foregroundStyle(tint)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(HopColor.tint(tint)))
                                .accessibilityHidden(true)
                            Text(step)
                                .font(.hopCaption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("Step \(index + 1): \(step)")
                    }
                }
                .padding(HopSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
            }
        }
        .padding(.vertical, HopSpacing.xs)
    }
}
