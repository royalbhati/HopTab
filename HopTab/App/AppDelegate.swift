import AppKit
import Combine

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
