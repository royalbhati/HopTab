import AppKit
import Combine
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppState: ObservableObject {
    let store = PinnedAppsStore()
    let permissions = PermissionsService()

    private let hotkeyService = HotkeyService()
    private let overlayController = OverlayWindowController()
    private let profileOverlayController = ProfileOverlayWindowController()

    @Published private(set) var selectedIndex: Int = 0
    @Published private(set) var isSwitcherVisible: Bool = false
    @Published var runningApps: [NSRunningApplication] = []
    @Published var recentAppFirst: Bool = UserDefaults.standard.bool(forKey: "recentAppFirst") {
        didSet {
            UserDefaults.standard.set(recentAppFirst, forKey: "recentAppFirst")
        }
    }


    @Published var appShortcutSelection: ShortcutSelection = ShortcutSelection.current {
        didSet {
            ShortcutSelection.current = appShortcutSelection
            applyAppShortcut()
            applyProfileShortcut()
        }
    }

    @Published var selectedPreset: ShortcutPreset? = nil

    @Published var isCustomAppShortcut: Bool = false

    @Published var customAppShortcut: CustomShortcut? = nil {
        didSet {
            guard isCustomAppShortcut, let c = customAppShortcut else { return }
            appShortcutSelection = .custom(c)
        }
    }


    @Published var isCustomProfileShortcut: Bool = ShortcutSelection.isCustomProfileShortcut {
        didSet {
            ShortcutSelection.isCustomProfileShortcut = isCustomProfileShortcut
            applyProfileShortcut()
        }
    }

    @Published var customProfileShortcut: CustomShortcut? = ShortcutSelection.savedProfileShortcut {
        didSet {
            ShortcutSelection.savedProfileShortcut = customProfileShortcut
            if isCustomProfileShortcut {
                applyProfileShortcut()
            }
        }
    }

    @Published private(set) var shortcutsConflict: Bool = false

    @Published private(set) var hotkeyStatus: HotkeyStatus = .stopped

    @Published private(set) var profileSelectedIndex: Int = 0
    @Published private(set) var isProfileSwitcherVisible: Bool = false

    @Published private(set) var profileShortcutModifierName: String = "Option"
    @Published private(set) var profileShortcutKeyName: String = "`"

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

        switch appShortcutSelection {
        case .preset(let p):
            selectedPreset = p
            isCustomAppShortcut = false
        case .custom(let c):
            selectedPreset = nil
            isCustomAppShortcut = true
            customAppShortcut = c
        }

        applyAppShortcut()
        applyProfileShortcut()
        refreshRunningApps()
        observeWorkspace()
        setupHotkeyCallbacks()
    }


    func selectPreset(_ preset: ShortcutPreset) {
        selectedPreset = preset
        isCustomAppShortcut = false
        appShortcutSelection = .preset(preset)
    }

    func selectCustomMode() {
        selectedPreset = nil
        isCustomAppShortcut = true
        if let c = customAppShortcut {
            appShortcutSelection = .custom(c)
        }
    }

    private func applyAppShortcut() {
        switch appShortcutSelection {
        case .preset(let p):
            hotkeyService.configure(preset: p)
        case .custom(let c):
            hotkeyService.configureAppShortcut(modifierFlag: c.modifierFlags, keyCode: c.keyCode)
        }
        checkConflicts()
    }

    private func applyProfileShortcut() {
        let modFlag: CGEventFlags
        let keyCode: Int64
        let modName: String
        let keyName: String

        if isCustomProfileShortcut, let c = customProfileShortcut {
            modFlag = c.modifierFlags
            keyCode = c.keyCode
            modName = c.modifierName
            keyName = c.keyName
        } else {
            if appShortcutSelection.modifierFlags == .maskAlternate &&
               appShortcutSelection.keyCode == Int64(kVK_ANSI_Grave) {
                modFlag = .maskControl
                keyCode = Int64(kVK_ANSI_Grave)
                modName = "Control"
            } else {
                modFlag = .maskAlternate
                keyCode = Int64(kVK_ANSI_Grave)
                modName = "Option"
            }
            keyName = "`"
        }

        hotkeyService.configureProfileShortcut(modifierFlag: modFlag, keyCode: keyCode)
        profileShortcutModifierName = modName
        profileShortcutKeyName = keyName
        checkConflicts()
    }

    private func checkConflicts() {
        let appFlags = appShortcutSelection.modifierFlags
        let appKey = appShortcutSelection.keyCode

        let profileFlags = hotkeyService.profileModifierFlag
        let profileKey = hotkeyService.profileTriggerKeyCode

        shortcutsConflict = appFlags == profileFlags && appKey == profileKey
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

        hotkeyService.onProfileSwitcherActivated = { [weak self] in
            self?.showProfileSwitcher()
        }

        hotkeyService.onProfileCycleForward = { [weak self] in
            self?.cycleProfileForward()
        }

        hotkeyService.onProfileCycleBackward = { [weak self] in
            self?.cycleProfileBackward()
        }

        hotkeyService.onProfileSwitcherDismissed = { [weak self] in
            self?.dismissAndActivateProfile()
        }

        hotkeyService.onProfileSwitcherCancelled = { [weak self] in
            self?.cancelProfileSwitcher()
        }
    }

    // MARK: - App Switcher Logic

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


    private func showProfileSwitcher() {
        let profiles = store.profiles
        guard profiles.count > 1 else {
            NSLog("[HopTab] Profile shortcut pressed but only %d profile(s) exist — need at least 2", profiles.count)
            return
        }

        let currentIndex = profiles.firstIndex { $0.id == store.activeProfileId } ?? 0
        profileSelectedIndex = (currentIndex + 1) % profiles.count

        isProfileSwitcherVisible = true
        profileOverlayController.show(profiles: profiles, selectedIndex: profileSelectedIndex)
    }

    private func cycleProfileForward() {
        let profiles = store.profiles
        guard !profiles.isEmpty else { return }
        profileSelectedIndex = (profileSelectedIndex + 1) % profiles.count
        profileOverlayController.update(profiles: profiles, selectedIndex: profileSelectedIndex)
    }

    private func cycleProfileBackward() {
        let profiles = store.profiles
        guard !profiles.isEmpty else { return }
        profileSelectedIndex = (profileSelectedIndex - 1 + profiles.count) % profiles.count
        profileOverlayController.update(profiles: profiles, selectedIndex: profileSelectedIndex)
    }

    private func dismissAndActivateProfile() {
        let profiles = store.profiles
        guard profileSelectedIndex < profiles.count else {
            cancelProfileSwitcher()
            return
        }

        let selected = profiles[profileSelectedIndex]
        profileOverlayController.dismiss()
        isProfileSwitcherVisible = false
        store.setActiveProfile(id: selected.id)
    }

    private func cancelProfileSwitcher() {
        profileOverlayController.dismiss()
        isProfileSwitcherVisible = false
    }


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
