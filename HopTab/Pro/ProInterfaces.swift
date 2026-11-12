import AppKit
import SwiftUI

// MARK: - Pro Links

/// Single source of truth for Pro purchase links.
enum ProLinks {
    static let purchaseURL = URL(string: "https://buy.polar.sh/polar_cl_iKgZQ7w4AWRhnNzsnQBl80syKnFJGHJj1Pv6d2a9tD7")!
}

// MARK: - Pro Provider Protocol

/// The main interface that the closed-source HopTabPro module implements.
/// The open-source app calls these methods when Pro is available.
protocol HopTabProProvider: AnyObject {
    // License
    var isLicensed: Bool { get }
    var licenseEmail: String? { get }
    func activate(licenseKey: String) -> Bool
    func deactivate()

    // Feature services — started after license validation
    func startServices(profileSwitcher: @escaping (UUID) -> Void, currentProfile: (() -> UUID?)?)
    func stopServices()

    // Focus mode
    var focusModeService: FocusModeServiceProtocol? { get }

    // Display auto-profiles
    var displayAutoProfileService: DisplayAutoProfileServiceProtocol? { get }

    // Window rules
    var windowRulesService: WindowRulesServiceProtocol? { get }

    // v2 Pro feature operations
    func windowUndo()
    func windowRedo()
    var canWindowUndo: Bool { get }
    var canWindowRedo: Bool { get }

    // Focus sessions
    func startFocusSession(minutes: Int, profileName: String, allowedBundleIds: [String])
    func stopFocusSession()
    /// nil when no session is running.
    var focusSessionRemainingMinutes: Int? { get }
    /// End a running focus session because the user switched away from its profile. No-op if none.
    func endFocusSessionForProfileSwitch()

    // Pomodoro (tied to a calendar event)
    /// Start a cyclic Pomodoro for an event. `eventEndDate` auto-stops it when set.
    func startPomodoro(eventTitle: String, eventEndDate: Date?)
    func stopPomodoro()
    /// Skip the current break and resume work. No-op outside a break.
    func skipPomodoroBreak()
    /// nil when no Pomodoro is running.
    var pomodoroStatus: PomodoroStatusInfo? { get }

    // Per-feature settings views. Each is the contents of a Form section;
    // nil when unlicensed.
    func windowUndoSectionView() -> AnyView?
    func screenBreaksSectionView() -> AnyView?
    func bspTilingSectionView() -> AnyView?
    func calendarSectionView(profiles: [ProProfileInfo]) -> AnyView?
    func scheduleSectionView(profiles: [ProProfileInfo]) -> AnyView?
    func focusModeSectionView(profiles: [ProProfileInfo]) -> AnyView?
    func timeTrackingSectionView() -> AnyView?

    /// Every Pro settings card this provider can render, with the metadata
    /// Settings needs to place and label it. Single source of truth — the
    /// `labsSectionViews` / `stableSectionViews` helpers are derived from it.
    ///
    /// Returns `[]` when the user is unlicensed.
    func proSectionDescriptors() -> [ProSectionDescriptor]

    // Per-section views for sidebar settings
    func windowsSectionView() -> AnyView?
    func displaysSectionView(profiles: [ProProfileInfo]) -> AnyView?
    func licenseSectionView() -> AnyView?

}

/// Defaults so future providers (or older builds of the Pro module) stay source-compatible.
extension HopTabProProvider {
    func bspTilingSectionView() -> AnyView? { nil }
    func calendarSectionView(profiles: [ProProfileInfo]) -> AnyView? { nil }
    func scheduleSectionView(profiles: [ProProfileInfo]) -> AnyView? { nil }
    func focusModeSectionView(profiles: [ProProfileInfo]) -> AnyView? { nil }
    func timeTrackingSectionView() -> AnyView? { nil }
    func proSectionDescriptors() -> [ProSectionDescriptor] { [] }

    /// Experimental sections, optionally narrowed to one part of Settings.
    ///
    /// Settings MUST render these under a single `ProLabs.title` heading with
    /// `ProLabs.warning` shown once above them — never mixed in with stable
    /// features. They are all default-off and some of them move or repaint the
    /// user's windows.
    func labsSectionViews(in placement: ProSectionPlacement? = nil) -> [ProSectionDescriptor] {
        proSectionDescriptors().filter {
            $0.isLabs && (placement == nil || $0.placement == placement)
        }
    }

    /// Non-experimental sections, optionally narrowed to one part of Settings.
    func stableSectionViews(in placement: ProSectionPlacement? = nil) -> [ProSectionDescriptor] {
        proSectionDescriptors().filter {
            !$0.isLabs && (placement == nil || $0.placement == placement)
        }
    }
}

// MARK: - Pro Settings Sections

/// Where a Pro settings card belongs in the sidebar.
enum ProSectionPlacement: String, CaseIterable, Sendable {
    case windows
    case layouts
    case automation
    case displays
}

/// One Pro settings card, plus what Settings needs to place and label it.
///
/// `isLabs` is the important field: a `true` here means the feature is
/// experimental and must be grouped under the Labs heading behind
/// `ProLabs.warning`, never presented alongside stable features.
struct ProSectionDescriptor: Identifiable {
    /// Stable key — safe to use for `ForEach` identity and for persisting
    /// per-section UI state (expanded / collapsed).
    let id: String
    let title: String
    let systemImage: String
    let placement: ProSectionPlacement
    let isLabs: Bool
    let view: AnyView

    init(
        id: String,
        title: String,
        systemImage: String,
        placement: ProSectionPlacement,
        isLabs: Bool,
        view: AnyView
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.placement = placement
        self.isLabs = isLabs
        self.view = view
    }
}

/// Copy and iconography for the Labs group. Centralised so every surface
/// that shows experimental features says the same thing.
enum ProLabs {
    static let title = "Labs — experimental"
    static let systemImage = "flask.fill"
    static let warning = "Experimental. These features move or repaint your windows and can misbehave with apps that resist Accessibility control. All are off by default — turn one on only if you want to help shape it."
}

// MARK: - Feature Service Protocols

protocol FocusModeServiceProtocol: AnyObject {
    /// Maps Focus mode name → profile UUID.
    var focusProfileMappings: [String: UUID] { get set }
    func start(profileSwitcher: @escaping (UUID) -> Void)
    func stop()
}

protocol DisplayAutoProfileServiceProtocol: AnyObject {
    /// Maps display config key (e.g. "1440x900+2560x1440") → profile UUID.
    var displayProfileMappings: [String: UUID] { get set }
    func start(profileSwitcher: @escaping (UUID) -> Void)
    func stop()
}

protocol WindowRulesServiceProtocol: AnyObject {
    var rules: [WindowRule] { get set }
    func start()
    func stop()
}

// MARK: - Window Undo

/// Tracks window position/size changes and supports multi-level undo.
protocol WindowUndoServiceProtocol: AnyObject {
    var isEnabled: Bool { get set }
    var maxHistorySize: Int { get set }
    var historyCount: Int { get }
    func start()
    func stop()
    func undo()
    func redo()
    var canUndo: Bool { get }
    var canRedo: Bool { get }
}

// MARK: - Screen Breaks

/// Workspace-aware screen break reminders.
protocol ScreenBreakServiceProtocol: AnyObject {
    var isEnabled: Bool { get set }
    /// Work interval in minutes before a break reminder.
    var workIntervalMinutes: Int { get set }
    /// Break duration in minutes.
    var breakDurationMinutes: Int { get set }
    func start()
    func stop()
    /// Skip the current break.
    func skipBreak()
    /// Start a break manually.
    func takeBreakNow()
}

// MARK: - Active Meeting Bridge

/// Protocol for querying active meeting state from the menu bar.
protocol ProActiveMeetingProvider {
    var activeMeetingTitle: String? { get }
    var activeMeetingURL: URL? { get }
    /// Next matched meeting (for the menu-bar HUD), or nil.
    var nextMeeting: (title: String, start: Date, url: URL?)? { get }
}

// MARK: - Pomodoro Status

/// Snapshot of the running Pomodoro for the menu bar. Mirrors the HopTabPro
/// module's session so the main app doesn't depend on module types.
struct PomodoroStatusInfo {
    let eventTitle: String
    /// True during a break interval, false during a work interval.
    let isBreak: Bool
    /// Seconds left in the current interval.
    let secondsRemaining: Int
    /// Work intervals completed so far this session.
    let completedIntervals: Int

    var phaseLabel: String { isBreak ? "Break" : "Focus" }
}

// MARK: - Menu Status

/// Everything the menu-bar panel shows about "now" from the Pro features,
/// read in one call so the panel never pokes five services itself.
struct ProMenuStatus {
    struct Meeting {
        let title: String
        let url: URL?
        /// nil while the meeting is in progress.
        let start: Date?
    }
    var meeting: Meeting?
    /// Seconds left in the running focus session, nil when none.
    var focusSessionSecondsRemaining: Int?
    var focusSessionProfileName: String?
    var pomodoro: PomodoroStatusInfo?
    /// Screen breaks: true when breaks are on at all.
    var screenBreaksEnabled: Bool
    var isOnBreak: Bool
    /// Seconds until the next break, nil when paused or off.
    var secondsUntilNextBreak: Int?
    /// Total seconds tracked across workspaces today.
    var trackedTodaySeconds: TimeInterval
    /// Top workspace today, if any.
    var topWorkspaceToday: (name: String, seconds: TimeInterval)?
}

protocol ProMenuStatusProvider {
    /// nil when unlicensed.
    var menuStatus: ProMenuStatus? { get }
    func takeBreakNow()
    func skipBreak()
}

// MARK: - Time Tracking Bridge

/// Optional protocol for time tracking — ProBridge conforms to this.
protocol ProBridgeTimeTracking {
    func recordProfileSwitch(profileId: UUID, profileName: String)
}

// MARK: - Pro Profile Info

/// Lightweight profile info passed to Pro views.
/// Mirrors the HopTabPro module's ProProfileInfo so the main app can construct it.
struct ProProfileInfo: Identifiable {
    let id: UUID
    let name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

// MARK: - Window Rule Model

struct WindowRule: Codable, Identifiable, Equatable {
    let id: UUID
    var bundleIdentifier: String
    var appDisplayName: String
    var snapDirection: SnapDirection
    var triggerOnLaunch: Bool
    var triggerOnFocus: Bool

    init(
        id: UUID = UUID(),
        bundleIdentifier: String,
        appDisplayName: String,
        snapDirection: SnapDirection,
        triggerOnLaunch: Bool = true,
        triggerOnFocus: Bool = false
    ) {
        self.id = id
        self.bundleIdentifier = bundleIdentifier
        self.appDisplayName = appDisplayName
        self.snapDirection = snapDirection
        self.triggerOnLaunch = triggerOnLaunch
        self.triggerOnFocus = triggerOnFocus
    }
}
