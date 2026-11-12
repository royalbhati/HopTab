import AppKit
import SwiftUI

// MARK: - Shared

/// Profiles in the shape Pro views take.
private func proProfiles(_ appState: AppState) -> [ProProfileInfo] {
    appState.store.profiles.map { ProProfileInfo(id: $0.id, name: $0.name) }
}

/// Locked state for a whole pane: the hero already explained the feature,
/// so this is just the unlock row.
private struct PaneUnlockRow: View {
    let feature: String

    var body: some View {
        Section {
            HStack(spacing: HopSpacing.md) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(HopColor.pro)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(feature) is part of HopTab Pro")
                        .font(.hopSubheading.weight(.medium))
                    Text("One-time purchase, every Pro feature, free updates.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: HopSpacing.sm)
                Link(destination: ProLinks.purchaseURL) {
                    Text("Unlock \u{2014} $5")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                Button("I have a key") { SettingsNavigation.open(.pro) }
                    .controlSize(.small)
            }
            .padding(.vertical, HopSpacing.xs)
        }
    }
}

// MARK: - Calendar

struct CalendarPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Section {
            FeatureHero(
                icon: "calendar",
                tint: .red,
                title: "Calendar",
                tagline: "Your meetings switch the workspace for you.",
                detail: "HopTab watches the calendars you choose. When an event with a video link is about to start it reminds you, switches to your meeting workspace, opens the link in the browser and profile you picked, and brings back the workspace you were in once the meeting ends.",
                steps: [
                    "Grant calendar access, then turn on Meeting Mode.",
                    "Pick the workspace to switch to and how early to be reminded.",
                    "Override any single event with its own workspace, apps and links.",
                ]
            )
        }

        if let provider = ProServiceRegistry.shared.provider, provider.isLicensed,
           let view = provider.calendarSectionView(profiles: proProfiles(appState)) {
            Section {
                view
            }
        } else {
            PaneUnlockRow(feature: "Calendar auto-switch")
            Section {
                lockedPreviewRow(icon: "sparkles", tint: HopColor.success, title: "Meeting Mode",
                                 detail: "Any event with a Zoom, Teams or Meet link switches you to the meeting workspace and opens the link.")
                lockedPreviewRow(icon: "bell.fill", tint: HopColor.warning, title: "Reminders",
                                 detail: "A HUD a few minutes before, with Join, Snooze and Not attending.")
                lockedPreviewRow(icon: "timer", tint: .pink, title: "Pomodoro per event",
                                 detail: "Start a focus cycle on an event and see focused time logged against it.")
                lockedPreviewRow(icon: "arrow.uturn.backward", tint: .blue, title: "Restore after",
                                 detail: "When the meeting ends, go back to the workspace you were in.")
            } header: {
                Text("What you get")
            }
        }
    }

    private func lockedPreviewRow(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: HopSpacing.md) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.hopSubheading.weight(.medium))
                Text(detail).font(.hopCaption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Time Tracking

struct TrackingPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Section {
            FeatureHero(
                icon: "chart.bar.xaxis",
                tint: .blue,
                title: "Time Tracking",
                tagline: "Know where your hours went, without starting a timer.",
                detail: "Every workspace switch is a timestamp. HopTab turns them into a daily split per workspace, the apps you spent longest in, focused time per calendar event, and a seven-day view. Set a daily limit on any app and get a quiet nudge when you pass it. Everything stays on this Mac.",
                steps: [
                    "Switch workspaces as you normally do \u{2014} nothing to start.",
                    "Open this pane for today\u{2019}s split, top apps and the weekly chart.",
                    "Use the \u{22EF} on an app to set a daily limit.",
                ]
            )
        }

        if let provider = ProServiceRegistry.shared.provider, provider.isLicensed,
           let view = provider.timeTrackingSectionView() {
            Section {
                view
            }
            FocusSessionSection()
        } else {
            PaneUnlockRow(feature: "Time tracking")
        }
    }
}

/// Start a timed focus session scoped to the active workspace. Lives here
/// because it is the one tracking feature you start by hand.
private struct FocusSessionSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var minutes = 25
    @State private var remaining: Int?
    @State private var tick: Timer?

    var body: some View {
        Section {
            if let remaining {
                LabeledContent {
                    Button("End session") {
                        ProServiceRegistry.shared.provider?.stopFocusSession()
                        refresh()
                    }
                    .controlSize(.small)
                } label: {
                    Label("\(remaining) min left in \(appState.store.activeProfile?.name ?? "this workspace")", systemImage: "moon.zzz.fill")
                }
            } else {
                LabeledContent {
                    HStack(spacing: HopSpacing.sm) {
                        Picker("Length", selection: $minutes) {
                            ForEach([15, 25, 45, 60, 90], id: \.self) { Text("\($0) min").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 100)
                        Button("Start") {
                            guard let profile = appState.store.activeProfile else { return }
                            ProServiceRegistry.shared.provider?.startFocusSession(
                                minutes: minutes,
                                profileName: profile.name,
                                allowedBundleIds: profile.pinnedApps.map(\.bundleIdentifier)
                            )
                            refresh()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(appState.store.activeProfile == nil)
                    }
                } label: {
                    Label("Focus session in \(appState.store.activeProfile?.name ?? "this workspace")", systemImage: "moon.zzz")
                }
            }
        } header: {
            Text("Focus Session")
        } footer: {
            Text("A timer scoped to the active workspace. Straying into an app that isn\u{2019}t pinned here gets a gentle nudge; switching workspaces ends the session.")
        }
        .onAppear {
            refresh()
            tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear { tick?.invalidate(); tick = nil }
    }

    private func refresh() {
        remaining = ProServiceRegistry.shared.provider?.focusSessionRemainingMinutes
    }
}

// MARK: - Screen Breaks

struct ScreenBreaksPane: View {
    var body: some View {
        Section {
            FeatureHero(
                icon: "cup.and.saucer.fill",
                tint: .teal,
                title: "Screen Breaks",
                tagline: "Rest on a schedule. Come back to exactly what you left.",
                detail: "After each work interval HopTab saves every window\u{2019}s position, covers the screen with a countdown, and puts everything back when the break ends. The clock pauses while you are idle, asleep, or in a calendar meeting, and stands down while a Pomodoro runs its own cycle.",
                steps: [
                    "Turn it on and choose how long to work and how long to rest.",
                    "Keep working \u{2014} the break screen appears on its own.",
                    "Press Esc to skip a break, or take one early from here.",
                ]
            )
        }

        if let provider = ProServiceRegistry.shared.provider, provider.isLicensed,
           let view = provider.screenBreaksSectionView() {
            Section {
                view
            }
            Section {
                LabeledContent("Idle") { Text("Pauses after 3 minutes without input").foregroundStyle(.secondary) }
                LabeledContent("Meetings") { Text("Never interrupts a calendar meeting").foregroundStyle(.secondary) }
                LabeledContent("Pomodoro") { Text("Defers to a running Pomodoro").foregroundStyle(.secondary) }
                LabeledContent("Sleep") { Text("Resets the clock when the Mac wakes").foregroundStyle(.secondary) }
            } header: {
                Text("When it stays quiet")
            }
        } else {
            PaneUnlockRow(feature: "Screen breaks")
        }
    }
}

// MARK: - Automation (schedule + Focus modes)

struct AutomationPane: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let provider = ProServiceRegistry.shared.provider, provider.isLicensed {
            if let schedule = provider.scheduleSectionView(profiles: proProfiles(appState)) {
                Section { schedule }
            }
            if let focus = provider.focusModeSectionView(profiles: proProfiles(appState)) {
                Section { focus }
            }
        } else {
            Section {
                ProLockedCard(
                    title: "Time Schedule",
                    description: "\u{201C}At 7 PM switch to Entertainment.\u{201D} Set it once, filter by weekday, and it runs every day.",
                    systemImage: "clock.badge"
                )
            }
            Section {
                ProLockedCard(
                    title: "Focus Mode Integration",
                    description: "Turning on the \u{201C}Work\u{201D} Focus switches you to your Work workspace. Map as many Focus modes as you like.",
                    systemImage: "moon.fill"
                )
            }
        }
    }
}
