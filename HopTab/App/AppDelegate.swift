import AppKit
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        if appState.permissions.isTrusted {
            appState.startHotkey()
        } else {
            // Prompt only on first-ever launch; poll silently afterwards
            appState.permissions.promptIfNeeded()

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

        // Bootstrap Pro module if available
        #if canImport(HopTabPro)
        let pro = ProBridge()
        ProServiceRegistry.shared.register(pro)
        let startProServices = { [weak self] in
            pro.startServices { profileId in
                self?.appState.activateProfile(id: profileId)
            }
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
