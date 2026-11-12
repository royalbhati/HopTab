import AppKit
import ApplicationServices
import Combine

#if canImport(HopTabPro)
import HopTabPro
#endif

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let appState = AppState()
    private var cancellables = Set<AnyCancellable>()
    private let onboardingController = OnboardingWindowController()
    let settingsController = SettingsWindowController()

    @objc func showOnboarding(_ sender: Any?) {
        onboardingController.show(appState: appState)
    }

    @objc func openSettings(_ sender: Any?) {
        settingsController.show(appState: appState)
    }

    /// hoptab:// deep links (Raycast, Shortcuts, Stream Deck, terminal `open`).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            appState.handleDeepLink(url)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Process-wide default for every AX call that doesn't set its own
        // timeout. AXUIElementSetMessagingTimeout on the system-wide element
        // sets the per-process default, so an unresponsive app can stall a
        // window query for 0.3s instead of the 6s system default — which is
        // what a hung Electron app used to cost us mid-snap. Individual call
        // sites (LayoutService, DragSnapService, AppSwitcherService) still set
        // their own; this is the floor for everything that forgets.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.3)

        // Diagnostics first: anything that crashes during the rest of launch
        // should still leave a local trace. Opt-in flag is
        // CrashReporter.enabledDefaultsKey; nothing is ever transmitted.
        CrashReporter.shared.start()

        if appState.permissions.isTrusted {
            appState.startHotkey()
        } else {
            if UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
                // Returning user lost the grant — re-prompt (first time only), then poll
                appState.permissions.promptIfNeeded()
            } else {
                // Onboarding owns the Accessibility prompt (it has its own CTA);
                // just poll silently so we pick up the grant when it lands.
                appState.permissions.startPolling()
            }

            // Start hotkey as soon as permission is granted
            appState.permissions.$isTrusted
                .removeDuplicates()
                .filter { $0 }
                .first()
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    self?.appState.startHotkey()
                }
                .store(in: &cancellables)
        }

        // Check for updates silently
        UpdateService.shared.checkOnLaunchIfNeeded()

        // Menu-bar meeting HUD (no-op without a licensed Pro module)
        appState.startMeetingHUD()

        // Bootstrap Pro module if available
        #if canImport(HopTabPro)
        let pro = ProBridge()
        ProServiceRegistry.shared.register(pro)
        let startProServices = { [weak self] in
            pro.startServices(
                profileSwitcher: { profileId in
                    self?.appState.activateProfile(id: profileId)
                },
                currentProfile: { self?.appState.store.activeProfileId }
            )
        }
        if pro.isLicensed {
            startProServices()
        }
        // Also start services when license is activated mid-session
        pro.module.licenseState.$isLicensed
            .removeDuplicates()
            .filter { $0 }
            .dropFirst(pro.isLicensed ? 1 : 0)  // Skip initial value if already licensed
            .receive(on: DispatchQueue.main)
            .sink { _ in
                startProServices()
            }
            .store(in: &cancellables)
        #endif

        // Show onboarding on first launch
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") {
            // Small delay so the menu bar is ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                self.onboardingController.show(appState: self.appState)
            }
        }
    }
}
