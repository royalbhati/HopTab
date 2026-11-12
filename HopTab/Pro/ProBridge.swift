/// Bridge between the closed-source HopTabPro package and the open-source app.
/// This file is compiled only when HopTabPro is available (#if canImport(HopTabPro)).
/// It adapts HopTabProModule to HopTabProProvider.

#if canImport(HopTabPro)
import HopTabPro
import SwiftUI

@MainActor
final class ProBridge: HopTabProProvider, ProBridgeTimeTracking, ProActiveMeetingProvider, ProMenuStatusProvider {
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

    func startServices(profileSwitcher: @escaping (UUID) -> Void, currentProfile: (() -> UUID?)? = nil) {
        // Let calendar/focus-mode restore logic detect manual mid-meeting switches
        module.calendar.currentProfileProvider = currentProfile
        module.focusMode.currentProfileProvider = currentProfile
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
        // Pomodoro start/end toasts
        module.pomodoro.onWorkStarted = { [weak self] title, minutes, interval in
            self?.toastController.show(
                icon: "timer",
                message: "Focus \(minutes)m on \(title) — interval \(interval)",
                duration: 2
            )
        }
        module.pomodoro.onSessionEnded = { [weak self] title, seconds in
            let mins = Int(seconds / 60)
            self?.toastController.show(
                icon: "checkmark.circle",
                message: "Pomodoro ended — \(mins)m focused on \(title)",
                duration: 3
            )
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

    // MARK: - Pomodoro

    func startPomodoro(eventTitle: String, eventEndDate: Date?) {
        module.pomodoro.start(eventTitle: eventTitle, eventEndDate: eventEndDate)
    }

    func stopPomodoro() {
        module.pomodoro.stop()
    }

    func skipPomodoroBreak() {
        module.pomodoro.skipBreak()
    }

    var pomodoroStatus: PomodoroStatusInfo? {
        guard let session = module.pomodoro.current else { return nil }
        return PomodoroStatusInfo(
            eventTitle: session.eventTitle,
            isBreak: session.phase.isBreak,
            secondsRemaining: max(0, Int(session.phaseEndsAt.timeIntervalSinceNow)),
            completedIntervals: session.completedWorkIntervals
        )
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

    // MARK: - Menu status

    var menuStatus: ProMenuStatus? {
        guard module.isLicensed else { return nil }
        var meeting: ProMenuStatus.Meeting?
        if let active = ActiveMeetingState.shared.activeMeeting, active.endDate > Date() {
            meeting = .init(title: active.title, url: active.meetingURL, start: nil)
        } else if let next = module.calendar.nextUpcomingMeeting(),
                  next.startDate.timeIntervalSinceNow < 2 * 3600 {
            meeting = .init(title: next.title, url: next.url, start: next.startDate)
        }
        let focus = module.focusSession.current
        let today = module.timeTracking.todaySummary()
        let total = today.reduce(0) { $0 + $1.totalSeconds }
        let top = today.max(by: { $0.totalSeconds < $1.totalSeconds })
        return ProMenuStatus(
            meeting: meeting,
            focusSessionSecondsRemaining: focus.map { max(0, Int($0.endsAt.timeIntervalSinceNow)) },
            focusSessionProfileName: focus?.profileName,
            pomodoro: pomodoroStatus,
            screenBreaksEnabled: module.screenBreak.isEnabled,
            isOnBreak: module.screenBreak.isOnBreak,
            secondsUntilNextBreak: module.screenBreak.secondsUntilNextBreak,
            trackedTodaySeconds: total,
            topWorkspaceToday: top.map { ($0.profileName, $0.totalSeconds) }
        )
    }

    func takeBreakNow() { module.screenBreak.takeBreakNow() }
    func skipBreak() { module.screenBreak.skipBreak() }

    var focusModeService: FocusModeServiceProtocol? { nil }
    var displayAutoProfileService: DisplayAutoProfileServiceProtocol? { nil }
    var windowRulesService: WindowRulesServiceProtocol? { nil }

    // MARK: - Window undo

    func windowUndo() { module.windowUndo.undo() }
    func windowRedo() { module.windowUndo.redo() }
    var canWindowUndo: Bool { module.windowUndo.canUndo }
    var canWindowRedo: Bool { module.windowUndo.canRedo }

    // MARK: - Per-feature settings views

    private func proProfiles(_ profiles: [ProProfileInfo]) -> [HopTabPro.ProProfileInfo] {
        profiles.map { HopTabPro.ProProfileInfo(id: $0.id, name: $0.name) }
    }

    func windowUndoSectionView() -> AnyView? {
        guard module.isLicensed else { return nil }
        return AnyView(WindowUndoConfigView(service: module.windowUndo))
    }

    func bspTilingSectionView() -> AnyView? {
        guard module.isLicensed else { return nil }
        return AnyView(BSPTilingConfigView(service: module.bspTiling))
    }

    func screenBreaksSectionView() -> AnyView? {
        guard module.isLicensed else { return nil }
        return AnyView(ScreenBreakConfigView(service: module.screenBreak))
    }

    func calendarSectionView(profiles: [ProProfileInfo]) -> AnyView? {
        guard module.isLicensed else { return nil }
        return AnyView(
            CalendarConfigView(calendarService: module.calendar, profiles: proProfiles(profiles), pomodoro: module.pomodoro)
        )
    }

    func scheduleSectionView(profiles: [ProProfileInfo]) -> AnyView? {
        guard module.isLicensed else { return nil }
        return AnyView(ScheduleConfigView(scheduleService: module.schedule, profiles: proProfiles(profiles)))
    }

    func focusModeSectionView(profiles: [ProProfileInfo]) -> AnyView? {
        guard module.isLicensed else { return nil }
        return AnyView(FocusModeConfigView(focusModeService: module.focusMode, profiles: proProfiles(profiles)))
    }

    func timeTrackingSectionView() -> AnyView? {
        guard module.isLicensed else { return nil }
        return AnyView(
            TimeTrackingView(timeTracking: module.timeTracking, appUsage: module.appUsage, pomodoro: module.pomodoro)
        )
    }

    // MARK: - Section Descriptors

    /// Which Pro cards exist, where they go, and which are experimental.
    /// Settings derives its Labs group from `labsSectionViews(in:)` and the
    /// rest from `stableSectionViews(in:)`.
    func proSectionDescriptors() -> [ProSectionDescriptor] {
        guard module.isLicensed else { return [] }

        var out: [ProSectionDescriptor] = []
        if let view = windowUndoSectionView() {
            out.append(ProSectionDescriptor(
                id: "window-undo", title: "Window Undo",
                systemImage: "arrow.uturn.backward",
                placement: .windows, isLabs: false, view: view
            ))
        }
        if let view = bspTilingSectionView() {
            out.append(ProSectionDescriptor(
                id: "bsp-tiling", title: "Auto-tiling (BSP)",
                systemImage: "rectangle.split.2x2",
                placement: .layouts, isLabs: true, view: view
            ))
        }
        return out
    }

    // MARK: - Per-Section Views

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
        if module.isLicensed {
            return AnyView(
                DisplayProfileConfigView(displayService: module.displayAutoProfile, profiles: proProfiles(profiles))
            )
        } else {
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Auto-switch profiles when monitors change")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Link(destination: ProLinks.purchaseURL) {
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
}
#endif
