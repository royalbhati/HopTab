/// Bridge between the closed-source HopTabPro package and the open-source app.
/// This file is compiled only when HopTabPro is available (#if canImport(HopTabPro)).
/// It adapts HopTabProModule to HopTabProProvider.

#if canImport(HopTabPro)
import HopTabPro
import SwiftUI

@MainActor
final class ProBridge: HopTabProProvider, ProBridgeTimeTracking, ProActiveMeetingProvider {
    let module = HopTabProModule()
    /// Long-lived toast — a throwaway controller would deallocate its panel
    /// before the toast finishes displaying.
    private let toastController = ToastOverlayController()
    private let digestController = StickyNoteOverlayController()

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
        // Wire undo failure toast (T4)
        module.windowUndo.onUndoFailed = { [weak self] message in
            self?.toastController.show(icon: "exclamationmark.circle", message: message)
        }
        // Focus session nudges + completion
        module.focusSession.onNudge = { [weak self] message in
            self?.toastController.show(icon: "moon.zzz", message: message, duration: 2.5)
        }
        module.focusSession.onEnded = { [weak self] message in
            self?.toastController.show(icon: "checkmark.circle", message: message, duration: 3)
        }
        // App budget nudges
        module.appUsage.onBudgetExceeded = { [weak self] appName, minutes in
            self?.toastController.show(icon: "hourglass", message: "\(appName): past your \(minutes)m daily limit", duration: 3)
        }
        // Weekly digest — sticky-note panel fits the multi-line summary
        module.onWeeklyDigest = { [weak self] digest in
            self?.digestController.show(profileName: "Last week in HopTab", note: digest, duration: 10)
        }
        module.startServices(profileSwitcher: profileSwitcher)
    }

    // MARK: - Focus Sessions

    func startFocusSession(minutes: Int, profileName: String, allowedBundleIds: [String]) {
        module.focusSession.start(minutes: minutes, profileName: profileName, allowedBundleIds: allowedBundleIds)
        toastController.show(icon: "moon.zzz.fill", message: "Focus session started — \(minutes) min in \(profileName)", duration: 2)
    }

    func stopFocusSession() {
        module.focusSession.stop()
    }

    var focusSessionRemainingMinutes: Int? {
        module.focusSession.remainingMinutes
    }

    /// A focus session is scoped to one profile; leaving that profile ends it.
    func endFocusSessionForProfileSwitch() {
        guard module.focusSession.isActive else { return }
        module.focusSession.stop()
        toastController.show(icon: "moon.zzz", message: "Focus session ended — switched profile", duration: 2)
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

    var nextMeeting: (title: String, start: Date, url: URL?)? {
        guard module.isLicensed,
              let next = module.calendar.nextUpcomingMeeting() else { return nil }
        return (next.title, next.startDate, next.url)
    }

    func stopServices() {
        module.stopServices()
    }

    var focusModeService: FocusModeServiceProtocol? { nil }
    var displayAutoProfileService: DisplayAutoProfileServiceProtocol? { nil }
    var windowRulesService: WindowRulesServiceProtocol? { nil }

    // MARK: - v2 Pro Feature Operations

    func windowUndo() { module.windowUndo.undo() }
    func windowRedo() { module.windowUndo.redo() }
    var canWindowUndo: Bool { module.windowUndo.canUndo }
    var canWindowRedo: Bool { module.windowUndo.canRedo }

    func declutterNow() -> Int { module.autoDeclutter.declutterNow() }

    func windowUndoSectionView() -> AnyView? {
        guard module.isLicensed else { return nil }
        return AnyView(WindowUndoConfigView(service: module.windowUndo))
    }

    func focusDimmingSectionView() -> AnyView? {
        return nil
    }

    func screenBreaksSectionView() -> AnyView? {
        guard module.isLicensed else { return nil }
        return AnyView(ScreenBreakConfigView(service: module.screenBreak))
    }

    // MARK: - Per-Section Views

    func profileSectionViews(profiles: [ProProfileInfo]) -> AnyView? {
        // Pro features no longer piggyback on the Profiles section — they
        // live in the dedicated Automation section.
        nil
    }

    func automationSectionView(profiles: [ProProfileInfo]) -> AnyView? {
        let proProfiles = profiles.map {
            HopTabPro.ProProfileInfo(id: $0.id, name: $0.name)
        }
        if module.isLicensed {
            return AnyView(
                VStack(alignment: .leading, spacing: 20) {
                    TimeTrackingView(timeTracking: module.timeTracking, appUsage: module.appUsage)
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
