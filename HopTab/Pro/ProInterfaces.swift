import AppKit
import SwiftUI

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
    func startServices(profileSwitcher: @escaping (UUID) -> Void)
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
    func declutterNow() -> Int
    func startPiP(windowID: CGWindowID, ownerPID: pid_t, ownerName: String, windowTitle: String)
    func stopAllPiPs()

    // v2 Pro settings views
    func proFeaturesView() -> AnyView?

    // Per-section views for sidebar settings
    func profileSectionViews(profiles: [ProProfileInfo]) -> AnyView?
    func windowsSectionView() -> AnyView?
    func displaysSectionView(profiles: [ProProfileInfo]) -> AnyView?
    func licenseSectionView() -> AnyView?
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

// MARK: - Auto-Declutter

/// Tracks window inactivity and auto-minimizes stale windows.
protocol AutoDeclutterServiceProtocol: AnyObject {
    var isEnabled: Bool { get set }
    /// Inactivity threshold in minutes before a window is considered stale.
    var staleThresholdMinutes: Int { get set }
    /// Bundle IDs excluded from decluttering.
    var excludedApps: [String] { get set }
    func start()
    func stop()
    /// Manually declutter all stale windows now.
    func declutterNow() -> Int
}

// MARK: - PiP (Picture-in-Picture)

/// Pins any window as a floating mini-preview.
protocol WindowPiPServiceProtocol: AnyObject {
    func startPiP(for windowInfo: PiPWindowInfo)
    func stopPiP(id: UUID)
    func stopAllPiPs()
    var activePiPs: [PiPWindowInfo] { get }
}

/// Info about a PiP'd window.
struct PiPWindowInfo: Identifiable {
    let id: UUID
    let windowID: CGWindowID
    let ownerPID: pid_t
    let ownerName: String
    let windowTitle: String

    init(id: UUID = UUID(), windowID: CGWindowID, ownerPID: pid_t, ownerName: String, windowTitle: String) {
        self.id = id
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.ownerName = ownerName
        self.windowTitle = windowTitle
    }
}

// MARK: - Smart Window Placement

/// Learns window placement patterns and auto-places new windows.
protocol SmartPlacementServiceProtocol: AnyObject {
    var isEnabled: Bool { get set }
    func start()
    func stop()
    /// Clear all learned patterns.
    func resetPatterns()
    var patternCount: Int { get }
}

// MARK: - Focus Dimming

/// Dims background windows to reduce distraction.
protocol FocusDimmingServiceProtocol: AnyObject {
    var isEnabled: Bool { get set }
    /// Opacity for background windows (0.0 = invisible, 1.0 = fully visible).
    var dimmingOpacity: Double { get set }
    func start()
    func stop()
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
