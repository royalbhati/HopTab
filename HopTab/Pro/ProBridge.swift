/// Bridge between the closed-source HopTabPro package and the open-source app.
/// This file is compiled only when HopTabPro is available (#if canImport(HopTabPro)).
/// It adapts HopTabProModule to HopTabProProvider.

#if canImport(HopTabPro)
import HopTabPro
import SwiftUI

@MainActor
final class ProBridge: HopTabProProvider, ProBridgeTimeTracking, ProActiveMeetingProvider {
    let module = HopTabProModule()

    var isLicensed: Bool { module.isLicensed }
    var licenseEmail: String? { module.licenseEmail }

    func activate(licenseKey: String) -> Bool {
        module.activate(licenseKey: licenseKey)
    }

    func deactivate() {
        module.deactivate()
    }

    func startServices(profileSwitcher: @escaping (UUID) -> Void) {
        // Set up the window rules snap callback to bridge into LayoutService
        WindowRulesService.snapCallback = { (bundleId: String, directionRawValue: String) in
            guard let direction = SnapDirection(rawValue: directionRawValue) else { return }
            LayoutService.snapApp(bundleIdentifier: bundleId, to: direction)
        }
        module.startServices(profileSwitcher: profileSwitcher)
    }

    /// Record a profile switch for time tracking.
    func recordProfileSwitch(profileId: UUID, profileName: String) {
        module.recordProfileSwitch(profileId: profileId, profileName: profileName)
    }

    // MARK: - Active Meeting

    var activeMeetingTitle: String? {
        ActiveMeetingState.shared.activeMeeting?.title
    }

    var activeMeetingURL: URL? {
        ActiveMeetingState.shared.activeMeeting?.meetingURL
    }

    func stopServices() {
        module.stopServices()
    }

    var focusModeService: FocusModeServiceProtocol? { nil }
    var displayAutoProfileService: DisplayAutoProfileServiceProtocol? { nil }
    var windowRulesService: WindowRulesServiceProtocol? { nil }

    // MARK: - Per-Section Views

    func profileSectionViews(profiles: [ProProfileInfo]) -> AnyView? {
        let proProfiles = profiles.map {
            HopTabPro.ProProfileInfo(id: $0.id, name: $0.name)
        }
        if module.isLicensed {
            return AnyView(
                VStack(alignment: .leading, spacing: 20) {
                    TimeTrackingView(timeTracking: module.timeTracking)
                    CalendarConfigView(calendarService: module.calendar, profiles: proProfiles)
                    ScheduleConfigView(scheduleService: module.schedule, profiles: proProfiles)
                    FocusModeConfigView(focusModeService: module.focusMode, profiles: proProfiles)
                }
            )
        } else {
            return AnyView(
                VStack(alignment: .leading, spacing: 16) {
                    // Upgrade banner
                    HStack(spacing: 12) {
                        Image(systemName: "star.circle.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.yellow)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("HopTab Pro")
                                .font(.system(size: 14, weight: .semibold))
                            Text("Automate your workspace — let HopTab switch for you")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Link(destination: URL(string: "https://buy.polar.sh/polar_cl_iKgZQ7w4AWRhnNzsnQBl80syKnFJGHJj1Pv6d2a9tD7")!) {
                            Text("$5 one-time")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor))
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.yellow.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.yellow.opacity(0.15), lineWidth: 1))
                    )

                    // Actual views rendered disabled with lock overlay
                    lockedView {
                        TimeTrackingView(timeTracking: module.timeTracking)
                    }
                    lockedView {
                        CalendarConfigView(calendarService: module.calendar, profiles: proProfiles)
                    }
                    lockedView {
                        ScheduleConfigView(scheduleService: module.schedule, profiles: proProfiles)
                    }
                    lockedView {
                        FocusModeConfigView(focusModeService: module.focusMode, profiles: proProfiles)
                    }
                }
            )
        }
    }

    func windowsSectionView() -> AnyView? {
        // Always show Window Rules — free tier gets 2 rules, Pro gets unlimited
        return AnyView(
            WindowRulesConfigView(
                windowRulesService: module.windowRules,
                maxFreeRules: 2,
                isLicensed: module.isLicensed
            )
        )
    }

    func displaysSectionView(profiles: [ProProfileInfo]) -> AnyView? {
        let proProfiles = profiles.map {
            HopTabPro.ProProfileInfo(id: $0.id, name: $0.name)
        }
        if module.isLicensed {
            return AnyView(
                DisplayProfileConfigView(displayService: module.displayAutoProfile, profiles: proProfiles)
            )
        } else {
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-switch profiles when monitors change")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Link(destination: URL(string: "https://buy.polar.sh/polar_cl_iKgZQ7w4AWRhnNzsnQBl80syKnFJGHJj1Pv6d2a9tD7")!) {
                        HStack(spacing: 4) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                            Text("Unlock with Pro — $5")
                                .font(.system(size: 11))
                        }
                    }
                }
            )
        }
    }

    func licenseSectionView() -> AnyView? {
        AnyView(
            LicenseEntryView(licenseState: module.licenseState)
        )
    }

    // MARK: - Locked View Overlay

    private func lockedView<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ZStack {
            content()
                .disabled(true)
                .opacity(0.4)
                .allowsHitTesting(false)

            // Lock overlay — click opens purchase link
            Color.clear
                .contentShape(Rectangle())
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .onTapGesture {
                    if let url = URL(string: "https://buy.polar.sh/polar_cl_iKgZQ7w4AWRhnNzsnQBl80syKnFJGHJj1Pv6d2a9tD7") {
                        NSWorkspace.shared.open(url)
                    }
                }
        }
    }
}
#endif
