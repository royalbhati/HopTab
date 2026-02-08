import AppKit
import Combine
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    let store = PinnedAppsStore()
    let permissions = PermissionsService()

    private let hotkeyService = HotkeyService()
    private let overlayController = OverlayWindowController()

    @Published private(set) var selectedIndex: Int = 0
    @Published private(set) var isSwitcherVisible: Bool = false
    @Published var runningApps: [NSRunningApplication] = []
    @Published var recentAppFirst: Bool = UserDefaults.standard.bool(forKey: "recentAppFirst") {
        didSet {
            UserDefaults.standard.set(recentAppFirst, forKey: "recentAppFirst")
        }
    }
    @Published var selectedShortcut: ShortcutPreset = ShortcutPreset.current {
        didSet {
            ShortcutPreset.current = selectedShortcut
            hotkeyService.configure(preset: selectedShortcut)
        }
    }
    @Published private(set) var hotkeyStatus: HotkeyStatus = .stopped

    enum HotkeyStatus: Equatable {
        case stopped
        case running
        case failed
    }

    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        // Forward store's changes so SwiftUI views update
        store.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        hotkeyService.configure(preset: selectedShortcut)
        refreshRunningApps()
        observeWorkspace()
        setupHotkeyCallbacks()
    }

    // MARK: - Hotkey Setup

    func startHotkey() {
        hotkeyService.start()
        hotkeyStatus = hotkeyService.isRunning ? .running : .failed
    }

    private func setupHotkeyCallbacks() {
        hotkeyService.onSwitcherActivated = { [weak self] in
            self?.showSwitcher()
        }

        hotkeyService.onCycleForward = { [weak self] in
            self?.cycleForward()
        }

        hotkeyService.onCycleBackward = { [weak self] in
            self?.cycleBackward()
        }

        hotkeyService.onSwitcherDismissed = { [weak self] in
            self?.dismissAndActivate()
        }

        hotkeyService.onSwitcherCancelled = { [weak self] in
            self?.cancelSwitcher()
        }

        hotkeyService.onTapFailed = { [weak self] in
            self?.hotkeyStatus = .failed
        }
    }

    // MARK: - Switcher Logic

    private func showSwitcher() {
        let apps = store.apps
        guard !apps.isEmpty else { return }

        selectedIndex = 0
        if apps.count > 1 {
            selectedIndex = 1
        }

        isSwitcherVisible = true
        overlayController.show(apps: apps, selectedIndex: selectedIndex)
    }

    private func cycleForward() {
        let apps = store.apps
        guard !apps.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % apps.count
        overlayController.update(apps: apps, selectedIndex: selectedIndex)
    }

    private func cycleBackward() {
        let apps = store.apps
        guard !apps.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + apps.count) % apps.count
        overlayController.update(apps: apps, selectedIndex: selectedIndex)
    }

    private func dismissAndActivate() {
        let apps = store.apps
        guard selectedIndex < apps.count else {
            cancelSwitcher()
            return
        }

        let selectedApp = apps[selectedIndex]
        overlayController.dismiss()
        isSwitcherVisible = false
        AppSwitcherService.activate(selectedApp)
        if recentAppFirst {
            store.moveToFront(bundleIdentifier: selectedApp.bundleIdentifier)
        }
    }

    private func cancelSwitcher() {
        overlayController.dismiss()
        isSwitcherVisible = false
    }

    // MARK: - Running Apps

    func refreshRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [NSNotification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ]
        for name in names {
            let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshRunningApps()
                }
            }
            workspaceObservers.append(observer)
        }

        // Auto-switch profile when the active Space changes
        let spaceObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleSpaceChange()
            }
        }
        workspaceObservers.append(spaceObserver)
    }

    private func handleSpaceChange() {
        guard let spaceId = SpaceService.currentSpaceId,
              let profileId = store.profileForSpace(spaceId)
        else { return }
        store.setActiveProfile(id: profileId)
    }

    /// Retry starting the event tap (e.g. after granting Accessibility).
    func retryHotkey() {
        hotkeyService.stop()
        hotkeyService.start()
        hotkeyStatus = hotkeyService.isRunning ? .running : .failed
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        hotkeyService.stop()
    }
}
