import AppKit
import Combine
import SwiftUI
import Carbon.HIToolbox

@MainActor
final class AppState: ObservableObject {
    let store = PinnedAppsStore()
    let permissions = PermissionsService()

    private let hotkeyService = HotkeyService()
    private let dragSnapService = DragSnapService()
    private let overlayController = OverlayWindowController()
    private let profileOverlayController = ProfileOverlayWindowController()
    private let windowPickerController = WindowPickerOverlayController()
    private let stickyNoteController = StickyNoteOverlayController()
    private let toastController = ToastOverlayController()

    @Published private(set) var selectedIndex: Int = 0
    @Published private(set) var isSwitcherVisible: Bool = false
    @Published var runningApps: [NSRunningApplication] = []
    @Published var installedApps: [InstalledAppsService.AppInfo] = []
    @Published var recentAppFirst: Bool = UserDefaults.standard.bool(forKey: "recentAppFirst") {
        didSet {
            UserDefaults.standard.set(recentAppFirst, forKey: "recentAppFirst")
        }
    }
    @Published var dragSnapEnabled: Bool = UserDefaults.standard.object(forKey: "dragSnapEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "dragSnapEnabled") {
        didSet {
            UserDefaults.standard.set(dragSnapEnabled, forKey: "dragSnapEnabled")
            dragSnapService.isEnabled = dragSnapEnabled
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

    // Window picker state
    @Published private(set) var isWindowPickerVisible: Bool = false
    @Published private(set) var windowPickerSelectedIndex: Int = 0
    private var windowPickerWindows: [WindowInfo] = []
    private var windowPickerApp: PinnedApp?

    enum HotkeyStatus: Equatable {
        case stopped
        case running
        case failed
    }

    private var cancellables = Set<AnyCancellable>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var profileSwitchWorkItems: [DispatchWorkItem] = []

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

        overlayController.onAppClicked = { [weak self] index in
            guard let self, self.isSwitcherVisible else { return }
            self.selectedIndex = index
            self.dismissAndActivate()
        }

        applyAppShortcut()
        applyProfileShortcut()
        syncProfileHotkeys()
        refreshRunningApps()
        refreshInstalledApps()
        observeWorkspace()
        setupHotkeyCallbacks()

        // Wire drag-to-snap
        dragSnapService.isEnabled = dragSnapEnabled
        hotkeyService.onMouseEvent = { [weak self] type, event in
            self?.dragSnapService.handleMouseEvent(type: type, event: event)
        }

        // Re-sync profile hotkeys whenever profiles change
        store.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncProfileHotkeys()
            }
            .store(in: &cancellables)
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

        NotificationCenter.default.addObserver(
            forName: .snapShortcutsChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hotkeyService.configureSnapShortcuts(SnapShortcutConfig.current)
        }
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

        // Per-profile hotkey callbacks
        hotkeyService.onProfileHotkeyActivated = { [weak self] profileId in
            self?.switchToProfile(id: profileId)
            self?.showSwitcher()
        }

        hotkeyService.onProfileHotkeyCycleForward = { [weak self] _ in
            self?.cycleForward()
        }

        hotkeyService.onProfileHotkeyCycleBackward = { [weak self] _ in
            self?.cycleBackward()
        }

        hotkeyService.onProfileHotkeyDismissed = { [weak self] _ in
            self?.dismissAndActivate()
        }

        // Cmd+Q/H/M callbacks
        hotkeyService.onQuitHighlighted = { [weak self] in
            self?.quitHighlightedApp()
        }

        hotkeyService.onHideHighlighted = { [weak self] in
            self?.hideHighlightedApp()
        }

        hotkeyService.onMinimizeHighlighted = { [weak self] in
            self?.minimizeHighlightedApp()
        }

        // Snap callbacks (arrow keys while switcher is active)
        hotkeyService.onSnapLeft = { [weak self] in
            self?.snapSelectedApp(direction: .left)
        }

        hotkeyService.onSnapRight = { [weak self] in
            self?.snapSelectedApp(direction: .right)
        }

        hotkeyService.onSnapFull = { [weak self] in
            self?.snapSelectedApp(direction: .full)
        }

        hotkeyService.onSnapBottom = { [weak self] in
            self?.snapSelectedApp(direction: .bottomHalf)
        }

        // Global snap shortcuts (work without switcher)
        hotkeyService.configureSnapShortcuts(SnapShortcutConfig.current)
        hotkeyService.onGlobalSnap = { direction in
            switch direction {
            case .nextMonitor:
                LayoutService.moveFrontmostToNextMonitor()
            case .previousMonitor:
                LayoutService.moveFrontmostToPreviousMonitor()
            case .undo:
                LayoutService.undoSnap()
            case .cycleNext:
                LayoutService.snapFrontmostCycle(forward: true)
            case .cyclePrevious:
                LayoutService.snapFrontmostCycle(forward: false)
            default:
                LayoutService.snapFrontmost(to: direction)
            }
        }

        // Window picker callbacks
        hotkeyService.onWindowPickerNavigateUp = { [weak self] in
            self?.windowPickerNavigateUp()
        }

        hotkeyService.onWindowPickerNavigateDown = { [weak self] in
            self?.windowPickerNavigateDown()
        }

        hotkeyService.onWindowPickerSelect = { [weak self] in
            self?.windowPickerSelect()
        }

        hotkeyService.onWindowPickerCancel = { [weak self] in
            self?.windowPickerCancel()
        }
    }

    // MARK: - App Switcher Logic

    /// Show overlay keyboard hints for the first few activations.
    private static let hintThreshold = 5
    private static let switcherCountKey = "switcherActivationCount"

    private var shouldShowHints: Bool {
        UserDefaults.standard.integer(forKey: Self.switcherCountKey) < Self.hintThreshold
    }

    private func incrementSwitcherCount() {
        let count = UserDefaults.standard.integer(forKey: Self.switcherCountKey)
        UserDefaults.standard.set(count + 1, forKey: Self.switcherCountKey)
    }

    private func showSwitcher() {
        let apps = store.apps

        selectedIndex = 0
        if apps.count > 1 {
            selectedIndex = 1
        }

        isSwitcherVisible = true
        overlayController.showHints = shouldShowHints
        overlayController.show(apps: apps, selectedIndex: selectedIndex)
        incrementSwitcherCount()
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
        guard isSwitcherVisible else { return }
        let apps = store.apps
        guard selectedIndex < apps.count else {
            cancelSwitcher()
            return
        }

        let selectedApp = apps[selectedIndex]
        overlayController.dismiss()
        isSwitcherVisible = false

        // Activate the app first so its windows come forward
        AppSwitcherService.activate(selectedApp)
        if recentAppFirst {
            store.moveToFront(bundleIdentifier: selectedApp.bundleIdentifier)
        }

        // If the app has 2+ windows on the current Space, show the window picker
        if let running = selectedApp.runningApplication {
            let allWindows = AppSwitcherService.enumerateWindows(of: running)
            let windows = AppSwitcherService.windowsOnCurrentSpace(allWindows)
            if windows.count >= 2 {
                showWindowPicker(app: selectedApp, windows: windows)
            }
        }
    }

    private func cancelSwitcher() {
        overlayController.dismiss()
        isSwitcherVisible = false
    }

    // MARK: - Window Picker

    private func showWindowPicker(app: PinnedApp, windows: [WindowInfo]) {
        windowPickerApp = app
        windowPickerWindows = windows
        windowPickerSelectedIndex = 0
        isWindowPickerVisible = true
        hotkeyService.enterWindowPickerMode()
        windowPickerController.show(
            appName: app.displayName,
            appIcon: app.icon,
            windows: windows,
            selectedIndex: 0
        )
    }

    private func windowPickerNavigateUp() {
        guard !windowPickerWindows.isEmpty else { return }
        windowPickerSelectedIndex = (windowPickerSelectedIndex - 1 + windowPickerWindows.count) % windowPickerWindows.count
        updateWindowPickerOverlay()
    }

    private func windowPickerNavigateDown() {
        guard !windowPickerWindows.isEmpty else { return }
        windowPickerSelectedIndex = (windowPickerSelectedIndex + 1) % windowPickerWindows.count
        updateWindowPickerOverlay()
    }

    private func windowPickerSelect() {
        guard windowPickerSelectedIndex < windowPickerWindows.count,
              let app = windowPickerApp?.runningApplication else {
            dismissWindowPicker()
            return
        }

        let window = windowPickerWindows[windowPickerSelectedIndex]
        dismissWindowPicker()
        AppSwitcherService.raiseWindow(of: app, windowID: window.id)
    }

    private func windowPickerCancel() {
        dismissWindowPicker()
    }

    private func dismissWindowPicker() {
        windowPickerController.dismiss()
        isWindowPickerVisible = false
        hotkeyService.exitWindowPickerMode()
        windowPickerWindows = []
        windowPickerApp = nil
    }

    private func updateWindowPickerOverlay() {
        guard let app = windowPickerApp else { return }
        windowPickerController.update(
            appName: app.displayName,
            appIcon: app.icon,
            windows: windowPickerWindows,
            selectedIndex: windowPickerSelectedIndex
        )
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
        switchToProfile(id: selected.id)
    }

    private func cancelProfileSwitcher() {
        profileOverlayController.dismiss()
        isProfileSwitcherVisible = false
    }


    private func syncProfileHotkeys() {
        hotkeyService.configureProfileHotkeys(store.profileHotkeys)
    }

    // MARK: - App Actions (Q/H/M)

    private func quitHighlightedApp() {
        let apps = store.apps
        guard selectedIndex < apps.count else { return }
        let app = apps[selectedIndex]
        app.runningApplication?.terminate()
        // Adjust selection after quit
        if apps.count > 1 {
            if selectedIndex >= apps.count - 1 {
                selectedIndex = max(0, apps.count - 2)
            }
            overlayController.update(apps: store.apps, selectedIndex: selectedIndex)
        } else {
            cancelSwitcher()
        }
    }

    private func hideHighlightedApp() {
        let apps = store.apps
        guard selectedIndex < apps.count else { return }
        let app = apps[selectedIndex]
        app.runningApplication?.hide()
        // Move to next app
        if apps.count > 1 {
            selectedIndex = (selectedIndex + 1) % apps.count
            overlayController.update(apps: apps, selectedIndex: selectedIndex)
        }
    }

    private func minimizeHighlightedApp() {
        let apps = store.apps
        guard selectedIndex < apps.count else { return }
        let app = apps[selectedIndex]
        if let running = app.runningApplication {
            AppSwitcherService.minimizeFirstWindow(of: running)
        }
        // Move to next app
        if apps.count > 1 {
            selectedIndex = (selectedIndex + 1) % apps.count
            overlayController.update(apps: apps, selectedIndex: selectedIndex)
        }
    }

    func refreshRunningApps() {
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
    }

    func refreshInstalledApps() {
        installedApps = InstalledAppsService.discoverInstalledApps()
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

    // MARK: - Session-Aware Profile Switching

    /// Public entry point for all UI-triggered profile switches.
    func activateProfile(id: UUID) {
        switchToProfile(id: id)
    }

    /// Cancel any in-flight delayed profile switch work (layout/snapshot restores).
    private func cancelPendingProfileWork() {
        for item in profileSwitchWorkItems { item.cancel() }
        profileSwitchWorkItems.removeAll()
    }

    private func scheduleProfileWork(delay: TimeInterval, block: @escaping () -> Void) {
        let item = DispatchWorkItem { block() }
        profileSwitchWorkItems.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Core profile switch: snapshot outgoing, hide, switch, unhide, restore incoming, show sticky note.
    private func switchToProfile(id: UUID) {
        let outgoingId = store.activeProfileId
        guard outgoingId != id else { return }

        // Cancel any pending layout/snapshot work from a previous rapid switch
        cancelPendingProfileWork()

        // 1. Snapshot outgoing profile
        if let outgoingId, let outgoing = store.profiles.first(where: { $0.id == outgoingId }) {
            let snapshot = SessionSnapshotService.captureSnapshot(for: outgoing)
            store.saveSnapshot(snapshot)
        }

        // 2. Get incoming profile
        guard let incoming = store.profiles.first(where: { $0.id == id }) else { return }

        // 3. Hide outgoing apps (except shared ones)
        if let outgoingId, let outgoing = store.profiles.first(where: { $0.id == outgoingId }) {
            SessionSnapshotService.hideProfileApps(outgoing, excluding: incoming)
        }

        // 4. Switch the active profile
        store.setActiveProfile(id: id)

        // 4b. Record for time tracking (Pro)
        if let provider = ProServiceRegistry.shared.provider as? ProBridgeTimeTracking {
            provider.recordProfileSwitch(profileId: id, profileName: incoming.name)
        }

        // 5. Unhide incoming apps
        SessionSnapshotService.unhideProfileApps(incoming)

        // 6. Apply layout or restore window positions after a small delay (let unhide take effect)
        if let binding = incoming.layoutBinding,
           let template = store.allTemplates.first(where: { $0.id == binding.templateId }),
           !binding.zoneAssignments.isEmpty {
            scheduleProfileWork(delay: 0.15) {
                LayoutService.applyLayout(binding: binding, template: template, profile: incoming)
            }
        } else if let snapshot = store.snapshot(for: id) {
            scheduleProfileWork(delay: 0.15) {
                SessionSnapshotService.restoreSnapshot(snapshot, for: incoming)
            }
        }

        // 7. Show sticky note if set
        if let note = incoming.stickyNote, !note.isEmpty {
            stickyNoteController.show(profileName: incoming.name, note: note)
        }
    }

    // MARK: - Save & Close / Restore Session

    /// Save window positions and quit all apps in a profile.
    func saveAndCloseSession(profileId: UUID) {
        guard let profile = store.profiles.first(where: { $0.id == profileId }) else { return }

        // Capture current window positions
        let snapshot = SessionSnapshotService.captureSnapshot(for: profile)
        store.saveSnapshot(snapshot)

        // Quit all running apps
        SessionSnapshotService.quitProfileApps(profile)
    }

    /// Relaunch all apps in a profile and restore their window positions.
    func restoreSession(profileId: UUID) {
        guard let profile = store.profiles.first(where: { $0.id == profileId }) else { return }

        // Cancel any pending work from a previous restore
        cancelPendingProfileWork()

        // Launch all apps
        SessionSnapshotService.launchProfileApps(profile)

        // Check if this profile has a layout binding — use that instead of snapshot
        if let binding = profile.layoutBinding,
           let template = store.allTemplates.first(where: { $0.id == binding.templateId }),
           !binding.zoneAssignments.isEmpty {
            // Apply layout after apps have had time to launch
            scheduleProfileWork(delay: 2.5) {
                LayoutService.applyLayout(binding: binding, template: template, profile: profile)
            }
            // Second attempt for slow-launching apps
            scheduleProfileWork(delay: 5.0) {
                LayoutService.applyLayout(binding: binding, template: template, profile: profile)
            }
        } else if let snapshot = store.snapshot(for: profileId) {
            // Restore saved window positions
            scheduleProfileWork(delay: 2.5) {
                SessionSnapshotService.restoreSnapshot(snapshot, for: profile)
            }
            // Second attempt for slow-launching apps
            scheduleProfileWork(delay: 5.0) {
                SessionSnapshotService.restoreSnapshot(snapshot, for: profile)
            }
        }

        // Show sticky note if set
        if let note = profile.stickyNote, !note.isEmpty {
            stickyNoteController.show(profileName: profile.name, note: note)
        }
    }

    /// Whether a profile has a saved session (snapshot exists and no apps are running).
    func canRestoreSession(profileId: UUID) -> Bool {
        guard let profile = store.profiles.first(where: { $0.id == profileId }),
              store.snapshot(for: profileId) != nil else { return false }
        return !SessionSnapshotService.hasRunningApps(profile)
    }

    // MARK: - Layout Actions

    /// Apply the active profile's layout template now.
    func applyLayoutForActiveProfile() {
        guard let profile = store.activeProfile else { return }
        guard let binding = profile.layoutBinding else { return }
        guard let template = store.allTemplates.first(where: { $0.id == binding.templateId }) else { return }
        guard !binding.zoneAssignments.isEmpty else { return }

        let result = LayoutService.applyLayout(binding: binding, template: template, profile: profile)
        if result == -1 {
            // AX not trusted — prompt and show error
            permissions.requestAccessibility()
            toastController.show(icon: "exclamationmark.triangle.fill", message: "Grant Accessibility in System Settings")
        } else if result == 0 {
            toastController.show(icon: "exclamationmark.circle", message: "No windows moved — are apps running?")
        } else {
            toastController.show(icon: "checkmark.circle.fill", message: "Layout Applied")
        }
    }

    /// Quick-snap the currently highlighted app in the switcher.
    func snapSelectedApp(direction: SnapDirection) {
        let apps = store.apps
        guard selectedIndex < apps.count else { return }
        let app = apps[selectedIndex]
        LayoutService.snapApp(bundleIdentifier: app.bundleIdentifier, to: direction)
    }

    private func handleSpaceChange() {
        guard let spaceId = SpaceService.currentSpaceId,
              let profileId = store.profileForSpace(spaceId)
        else { return }
        switchToProfile(id: profileId)
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
