import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General Section

struct GeneralSection: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var requiresApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var registrationError: String?

    var body: some View {
        Section {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    setLaunchAtLogin(launchAtLogin)
                }

            if requiresApproval {
                HopBanner(
                    icon: "exclamationmark.triangle.fill",
                    tone: HopColor.warning,
                    title: "macOS needs your approval to launch HopTab at login.",
                    detail: nil
                ) {
                    Button("Open Login Items Settings") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .controlSize(.small)
                }
            }

            if let registrationError {
                Text(registrationError)
                    .font(.hopCaption)
                    .foregroundStyle(HopColor.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Startup")
        }
        .onAppear { refreshStatus() }
    }

    private func refreshStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        // Ignore programmatic toggles from refreshStatus().
        guard enabled != (SMAppService.mainApp.status == .enabled) else { return }
        registrationError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            registrationError = "Couldn't update login item: \(error.localizedDescription)"
        }
        refreshStatus()
    }
}

// MARK: - Permissions Section
//
// One consistent treatment for Accessibility, reused everywhere in Settings
// that needs it (the app previously had three different prompts).

struct PermissionsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Section {
            AccessibilityStatusRow()

            if appState.isSecureInputActive {
                HopBanner(
                    icon: "lock.fill",
                    tone: HopColor.warning,
                    title: "Shortcuts are paused",
                    detail: "An app has keyboard security on \u{2014} usually a password field in Safari, a terminal, or a password manager. macOS blocks every global shortcut while that is active. Click out of the password field and HopTab resumes on its own."
                ) {
                    EmptyView()
                }
            }
        } header: {
            Text("Permissions")
        } footer: {
            Text("HopTab needs Accessibility access to move, resize, and raise windows. It never reads your keystrokes outside its own shortcuts.")
        }
    }
}

/// Single source of truth for how a missing Accessibility grant is presented.
struct AccessibilityStatusRow: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if appState.isAccessibilityTrusted {
            LabeledContent {
                HStack(spacing: HopSpacing.xs) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(HopColor.success)
                        .accessibilityHidden(true)
                    Text("Granted")
                        .foregroundStyle(HopColor.success)
                }
                .font(.hopSubheading)
            } label: {
                Label("Accessibility", systemImage: "accessibility")
            }
        } else {
            HopBanner(
                icon: "exclamationmark.triangle.fill",
                tone: HopColor.warning,
                title: "Accessibility access is off",
                detail: appState.permissions.canShowSystemPrompt
                    ? "HopTab can't move or raise windows until macOS grants it Accessibility access."
                    : "macOS only offers its one-time dialog once. Turn HopTab on in System Settings \u{203A} Privacy & Security \u{203A} Accessibility."
            ) {
                Button(appState.permissions.canShowSystemPrompt ? "Grant Access" : "Open System Settings") {
                    // `requestAccessibility()` already falls back to opening
                    // System Settings once the dialog can no longer appear.
                    appState.permissions.requestAccessibility()
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - Switcher Behavior

struct SwitcherBehaviorSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Section {
            Toggle("Move recently switched app to front", isOn: $appState.recentAppFirst)
        } header: {
            Text("Behavior")
        } footer: {
            Text("Reorders a workspace\u{2019}s apps by how recently you used them, so \u{2325}Tab-release always flips to the previous one.")
        }
    }
}

// MARK: - Advanced Space Control Section

struct AdvancedSpaceControlSection: View {
    @State private var isExpanded = false
    @State private var sipStatus: SpaceService.SIPStatus?
    @AppStorage("advancedSpaceControlEnabled") private var advancedSpaceControlEnabled = false

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: HopSpacing.sm) {
                    sipStatusRow

                    switch sipStatus {
                    case .disabled, .partiallyDisabled:
                        Toggle("Advanced space control", isOn: $advancedSpaceControlEnabled)
                        Text("Available on this Mac. When on, switching to a profile with an assigned desktop jumps directly to that desktop, without the Mission Control animation.")
                            .font(.hopFootnote)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    case .enabled, .unknown, nil:
                        Text("HopTab's tiling, snapping, and profiles work fully with System Integrity Protection on. A small set of extras \u{2014} instant desktop switching without animation, window opacity effects \u{2014} would require reducing SIP the way yabai users do. HopTab does not recommend this for most users: it weakens macOS security, must be redone from Recovery mode, and can break on macOS updates.")
                            .font(.hopCaption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Link("Learn more about advanced space control",
                             destination: URL(string: "https://hoptab.app/guides/advanced-space-control")!)
                            .font(.hopCaption)
                    }
                }
                .padding(.top, HopSpacing.xs)
            } label: {
                Text("Advanced")
                    .font(.hopSubheading)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            // csrutil spawns a process — query off the main actor, cached after.
            sipStatus = await Task.detached(priority: .utility) { SpaceService.sipStatus }.value
        }
    }

    private var sipStatusRow: some View {
        LabeledContent {
            Text(sipStatusLabel)
                .font(.hopCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } label: {
            Label("System Integrity Protection", systemImage: "lock.shield")
                .foregroundStyle(.secondary)
        }
    }

    private var sipStatusLabel: String {
        switch sipStatus {
        case .enabled: return "Enabled"
        case .partiallyDisabled: return "Custom configuration \u{2014} advanced space control available"
        case .disabled: return "Disabled \u{2014} advanced space control available"
        case .unknown: return "Unknown"
        case nil: return "Checking\u{2026}"
        }
    }
}

// MARK: - About Section

struct AboutSection: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var updateService = UpdateService.shared

    var body: some View {
        Section {
            VStack(spacing: HopSpacing.md) {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)

                Text("HopTab")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .foregroundStyle(.secondary)

                Text("A supercharged macOS app switcher.\nPin your favorite apps and switch between them instantly.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal)

                Button {
                    UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                    NSApp.sendAction(#selector(AppDelegate.showOnboarding(_:)), to: nil, from: nil)
                } label: {
                    Label("Show Onboarding", systemImage: "book.pages")
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, HopSpacing.sm)
        }

        Section("Updates") {
            Toggle("Check for updates automatically", isOn: $updateService.autoCheckEnabled)

            HStack {
                Button {
                    Task { await updateService.checkForUpdates(silent: false) }
                } label: {
                    HStack(spacing: HopSpacing.xs) {
                        if updateService.isChecking {
                            ProgressView()
                                .controlSize(.small)
                                .scaleEffect(0.7)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        Text("Check for Updates")
                    }
                }
                .controlSize(.small)
                .disabled(updateService.isChecking)

                Spacer()

                if let update = updateService.availableUpdate {
                    Button {
                        updateService.downloadUpdate(update)
                    } label: {
                        Label("v\(update.version) Available", systemImage: "arrow.down.circle.fill")
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                }
            }
        }

        // The license field now lives in its own section, so there is exactly
        // one place to look for it.
        Section {
            LabeledContent {
                Button("Open Pro") { SettingsNavigation.open(.pro) }
                    .controlSize(.small)
            } label: {
                Label(
                    ProServiceRegistry.shared.isLicensed ? "Pro is active" : "Enter a license key",
                    systemImage: "key"
                )
            }
        } header: {
            Text("License")
        }
    }
}
