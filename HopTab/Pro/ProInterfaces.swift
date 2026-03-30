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
