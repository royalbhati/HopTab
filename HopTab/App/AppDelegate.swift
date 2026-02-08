import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let appState = AppState()
    private var cancellables = Set<AnyCancellable>()

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
    }
}
