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
    @Published var dragSnapEnabled: Bool = UserDefaults.standard.object(forKey: "dragSnapEnabled") == nil ? false : UserDefaults.standard.bool(forKey: "dragSnapEnabled") {
        didSet {
            UserDefaults.standard.set(dragSnapEnabled, forKey: "dragSnapEnabled")
            dragSnapService.isEnabled = dragSnapEnabled
            hotkeyService.includeMouseEvents = dragSnapEnabled
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

    /// Set when a windows-to-Space move verifiably failed (macOS restricted
    /// CGSMoveWindowsToManagedSpace, 14.5+). Persisted so settings can show
    /// "not supported on this macOS version" across launches.
    @Published private(set) var spaceMoveUnsupported: Bool =
        UserDefaults.standard.bool(forKey: "spaceMoveUnsupported")

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
    /// Menu-bar HUD text for the imminent/active meeting ("Standup in 4m"),
    /// or nil to show the plain icon. Refreshed every 30s.
    @Published private(set) var meetingHUD: String?
    private var meetingHUDTimer: Timer?

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
    /// True while `switchToProfile` is in flight or its scheduled tail is still running.
    /// Stage Manager fires `activeSpaceDidChangeNotification` on every stage transition,
    /// so this flag suppresses re-entrant space-driven switches that would oscillate
    /// between space-bound profiles.
    private var isApplyingProfile: Bool = false
    /// Target profile of the switch currently mid-apply, or nil. Guards against
    /// double-fires to the same target and profile deep links during a switch.
    private var inFlightProfileSwitchId: UUID?
    /// A genuine space change arrived while `isApplyingProfile` suppressed it —
    /// re-evaluate it when the apply completes instead of dropping it.
    private var pendingSpaceChangeDuringApply = false
    /// Observer for apps launching during a readiness-driven session restore.
    private var restoreLaunchObserver: NSObjectProtocol?
    /// Observer for display configuration changes (NotificationCenter.default).
    private var screenParamsObserver: NSObjectProtocol?
    private let spaceChangeSubject = PassthroughSubject<Void, Never>()

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

        // Wire drag-to-snap (only tap mouse events when enabled to avoid idle CPU)
        dragSnapService.isEnabled = dragSnapEnabled
        hotkeyService.includeMouseEvents = dragSnapEnabled
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

        // Warm the SIP status cache off-main so the first profile switch and
        // the settings Advanced section never block on spawning csrutil.
        DispatchQueue.global(qos: .utility).async {
            _ = SpaceService.sipStatus
        }

        // Coalesce Stage Manager's rapid-fire space-change notifications.
        spaceChangeSubject
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.handleSpaceChange()
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
            // switchToProfile applies its changes on the next main-queue turn;
            // enqueue the switcher behind it so the overlay shows the *new*
            // profile's apps rather than the outgoing one's.
            DispatchQueue.main.async { self?.showSwitcher() }
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
        hotkeyService.onGlobalSnap = { [weak self] direction in
            self?.performSnapAction(direction)
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

        hotkeyService.onExpandWindows = { [weak self] in
            self?.expandSelectedAppWindows()
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

    /// Space pressed on a highlighted app while the switcher is open —
    /// drill into that app's windows on the current Space.
    private func expandSelectedAppWindows() {
        guard isSwitcherVisible else { return }
        let apps = store.apps
        guard selectedIndex < apps.count else { return }

        let selectedApp = apps[selectedIndex]
        guard let running = selectedApp.runningApplication else { return }

        let allWindows = AppSwitcherService.enumerateWindows(of: running)
        let windows = AppSwitcherService.windowsOnCurrentSpace(allWindows)
        guard !windows.isEmpty else { return }

        AppSwitcherService.activate(selectedApp)
        if recentAppFirst {
            store.moveToFront(bundleIdentifier: selectedApp.bundleIdentifier)
        }

        overlayController.dismiss()
        isSwitcherVisible = false

        showWindowPicker(app: selectedApp, windows: windows)
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

        // Auto-switch profile when the active Space changes.
        // Route through `spaceChangeSubject` so the debounce in init() can coalesce
        // bursts (Stage Manager emits one notification per stage animation).
        let spaceObserver = center.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.spaceChangeSubject.send()
            }
        }
        workspaceObservers.append(spaceObserver)

        // Cancel in-flight window positioning when the display configuration
        // changes — pending frames were computed for a config that no longer exists.
        screenParamsObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleScreenParametersChanged()
            }
        }
    }

    private func handleScreenParametersChanged() {
        guard isApplyingProfile else { return }
        cancelPendingProfileWork()
        finishProfileApply()
    }

    // MARK: - Snap Actions

    /// Perform a snap action on the frontmost window. Shared by the global
    /// hotkeys and hoptab:// deep links.
    func performSnapAction(_ direction: SnapDirection) {
        switch direction {
        case .nextMonitor:
            LayoutService.moveFrontmostToNextMonitor()
        case .previousMonitor:
            LayoutService.moveFrontmostToPreviousMonitor()
        case .undo:
            // Use Pro Window Undo if available (tracks all moves, not just snaps)
            if let provider = ProServiceRegistry.shared.provider, provider.canWindowUndo {
                provider.windowUndo()
            } else {
                LayoutService.undoSnap()
            }
        case .redo:
            if let provider = ProServiceRegistry.shared.provider, provider.canWindowRedo {
                provider.windowRedo()
            }
        case .cycleNext:
            LayoutService.snapFrontmostCycle(forward: true)
        case .cyclePrevious:
            LayoutService.snapFrontmostCycle(forward: false)
        default:
            LayoutService.snapFrontmost(to: direction)
        }
    }

    // MARK: - Meeting HUD (Pro)

    /// Start the 30s refresh loop for the menu-bar meeting HUD. Cheap no-op
    /// each tick when Pro isn't installed/licensed.
    func startMeetingHUD() {
        guard meetingHUDTimer == nil else { return }
        updateMeetingHUD()
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateMeetingHUD() }
        }
        timer.tolerance = 5
        meetingHUDTimer = timer
    }

    private func updateMeetingHUD() {
        guard let provider = ProServiceRegistry.shared.provider,
              provider.isLicensed,
              let meetings = provider as? ProActiveMeetingProvider
        else {
            if meetingHUD != nil { meetingHUD = nil }
            return
        }

        var text: String?
        if let title = meetings.activeMeetingTitle {
            text = "\(Self.hudTitle(title)) · now"
        } else if let next = meetings.nextMeeting {
            let minutes = max(0, Int(ceil(next.start.timeIntervalSinceNow / 60)))
            if minutes <= 15 {
                text = "\(Self.hudTitle(next.title)) in \(minutes)m"
            }
        }
        if meetingHUD != text { meetingHUD = text }
    }

    private static func hudTitle(_ title: String) -> String {
        title.count > 18 ? String(title.prefix(17)) + "…" : title
    }

    // MARK: - Focus Sessions (Pro)

    /// Start a focus session scoped to the active profile's pinned apps.
    func startFocusSession(minutes: Int) {
        guard let provider = ProServiceRegistry.shared.provider, provider.isLicensed else { return }
        let profile = store.activeProfile
        provider.startFocusSession(
            minutes: minutes,
            profileName: profile?.name ?? "your profile",
            allowedBundleIds: (profile?.pinnedApps ?? []).map(\.bundleIdentifier)
        )
    }

    // MARK: - Deep Links (hoptab://)

    /// Routes hoptab:// URLs:
    ///   hoptab://profile/<name>   switch to the named profile
    ///   hoptab://snap/<direction> snap the frontmost window (e.g. left, topRight)
    ///   hoptab://undo, hoptab://redo
    ///   hoptab://focus/<minutes>  start a focus session (Pro)
    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "hoptab" else { return }
        let action = url.host?.lowercased() ?? ""
        let argument = url.pathComponents.count > 1 ? url.pathComponents[1] : nil

        switch action {
        case "profile":
            // Ignore deep links while a switch is mid-apply
            guard inFlightProfileSwitchId == nil,
                  let name = argument?.removingPercentEncoding else { return }
            // Prefer an exact-case match when multiple profiles share a name
            let candidates = store.profiles.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            guard let profile = candidates.first(where: { $0.name == name }) ?? candidates.first
            else { return }
            activateProfile(id: profile.id)
        case "snap":
            guard let raw = argument,
                  let direction = SnapDirection(rawValue: raw)
                    ?? SnapDirection.allCases.first(where: { $0.rawValue.lowercased() == raw.lowercased() })
            else { return }
            performSnapAction(direction)
        case "undo":
            performSnapAction(.undo)
        case "redo":
            performSnapAction(.redo)
        case "focus":
            startFocusSession(minutes: Int(argument ?? "") ?? 25)
        default:
            break
        }
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
        if let observer = restoreLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            restoreLaunchObserver = nil
        }
    }

    private func scheduleProfileWork(delay: TimeInterval, block: @escaping () -> Void) {
        var item: DispatchWorkItem!
        item = DispatchWorkItem { [weak self] in
            block()
            // Prune executed items so the list doesn't grow until the next switch
            if let self, let item { self.profileSwitchWorkItems.removeAll { $0 === item } }
        }
        profileSwitchWorkItems.append(item)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Release the space-change suppression and clear the in-flight switch token,
    /// then re-evaluate any space change that arrived while suppressed.
    private func finishProfileApply() {
        isApplyingProfile = false
        inFlightProfileSwitchId = nil
        if pendingSpaceChangeDuringApply {
            pendingSpaceChangeDuringApply = false
            handleSpaceChange()
        }
    }

    /// Core profile switch: snapshot outgoing, hide, switch, unhide, restore incoming, show sticky note.
    private func switchToProfile(id: UUID) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // A second switch to the same target while one is mid-apply is a no-op.
            guard self.inFlightProfileSwitchId != id else { return }

            // Read the active profile *inside* the async block — two rapid switches
            // would otherwise both capture the same stale outgoingId, and the second
            // would re-snapshot the outgoing profile after its apps were hidden,
            // corrupting its saved layout.
            let outgoingId = self.store.activeProfileId
            guard outgoingId != id else { return }

            // Resolve the incoming profile before touching any state — an early
            // return after `isApplyingProfile = true` would leave the flag stuck
            // and silently disable space-driven auto-switching until relaunch.
            guard let incoming = self.store.profiles.first(where: { $0.id == id }) else { return }

            // Cancel any pending layout/snapshot work from a previous rapid switch
            self.cancelPendingProfileWork()
            self.inFlightProfileSwitchId = id

            // Suppress space-driven re-entry while we hide/unhide/move windows.
            // Stage Manager animates each activation as a stage transition and fires
            // `activeSpaceDidChangeNotification` with a fresh spaceId, which would
            // otherwise resolve to a different space-bound profile and oscillate.
            self.isApplyingProfile = true

            // 1. Snapshot outgoing profile
            if let outgoingId, let outgoing = self.store.profiles.first(where: { $0.id == outgoingId }) {
                let snapshot = SessionSnapshotService.captureSnapshot(for: outgoing)
                self.store.saveSnapshot(snapshot)
            }

            // 3. Hide outgoing apps (except shared ones)
            if let outgoingId, let outgoing = self.store.profiles.first(where: { $0.id == outgoingId }) {
                SessionSnapshotService.hideProfileApps(outgoing, excluding: incoming)
            }

            // 4. Switch the active profile
            self.store.setActiveProfile(id: id)

            // 4b. Record for time tracking (Pro)
            if let provider = ProServiceRegistry.shared.provider as? ProBridgeTimeTracking {
                provider.recordProfileSwitch(profileId: id, profileName: incoming.name)
            }

            // 4c. A focus session is scoped to the outgoing profile — end it (Pro).
            ProServiceRegistry.shared.provider?.endFocusSessionForProfileSwitch()

            // 5. Unhide incoming apps
            SessionSnapshotService.unhideProfileApps(incoming)

            // 5b. Advanced space control (opt-in). Both run inside the
            // isApplyingProfile window, so the space-change events they trigger
            // can't recursively fire auto-switching.
            if let assignedSpaceId = self.store.spaceForProfile(id) {
                // Direct Space switch via CGS — only when SIP is reduced and the
                // Advanced toggle is on. Falls back silently (returns false) to
                // the default behavior otherwise.
                if UserDefaults.standard.bool(forKey: "advancedSpaceControlEnabled"),
                   SpaceService.sipStatus != .enabled {
                    _ = SpaceService.switchToSpace(spaceId: assignedSpaceId)
                }

                // Move the profile's app windows onto its assigned Space (works
                // with SIP fully enabled). Small delay so unhide takes effect
                // and windows are enumerable.
                if self.store.movesWindowsToAssignedSpace(id) {
                    self.scheduleProfileWork(delay: 0.2) { [weak self] in
                        self?.moveProfileWindows(incoming, toSpaceId: assignedSpaceId)
                    }
                }
            }

            // 6. Apply layout or restore window positions after a small delay (let unhide take effect)
            if let binding = incoming.layoutBinding,
               let template = self.store.allTemplates.first(where: { $0.id == binding.templateId }),
               !binding.zoneAssignments.isEmpty {
                self.scheduleProfileWork(delay: 0.15) {
                    LayoutService.applyLayout(binding: binding, template: template, profile: incoming)
                }
            } else if let snapshot = self.store.snapshot(for: id) {
                self.scheduleProfileWork(delay: 0.15) {
                    SessionSnapshotService.restoreSnapshot(snapshot, for: incoming)
                }
            }

            // 7. Move apps to their assigned displays (if multi-monitor)
            self.applyDisplayAssignments(for: incoming)

            // 8. Show sticky note if set
            if let note = incoming.stickyNote, !note.isEmpty {
                self.stickyNoteController.show(profileName: incoming.name, note: note)
            }

            // 9. Release the space-change suppression after the second
            // applyDisplayAssignments wave (+2.5s) plus a buffer for Stage Manager
            // animation aftershocks. Tracked through scheduleProfileWork so a
            // rapid follow-up switch cancels and re-arms it.
            self.scheduleProfileWork(delay: 3.0) { [weak self] in
                self?.finishProfileApply()
            }
        }
    }

    /// Move a profile's app windows to a Space (opt-in per profile, no SIP
    /// needed). Minimized windows and windows already on the target Space are
    /// skipped. On verifiable failure (macOS restricted the call), records
    /// `spaceMoveUnsupported` and silently leaves hide-based behavior in place.
    private func moveProfileWindows(_ profile: Profile, toSpaceId spaceId: Int) {
        var windowIDs: [CGWindowID] = []
        for app in profile.pinnedApps {
            guard let running = app.runningApplication else { continue }
            for window in AppSwitcherService.enumerateWindows(of: running)
            where !window.isMinimized && window.spaceID != spaceId {
                windowIDs.append(window.id)
            }
        }
        guard !windowIDs.isEmpty else { return }

        let success = SpaceService.moveWindows(windowIDs, toSpaceId: spaceId)
        if success {
            if spaceMoveUnsupported {
                spaceMoveUnsupported = false
                UserDefaults.standard.set(false, forKey: "spaceMoveUnsupported")
            }
        } else if !spaceMoveUnsupported {
            spaceMoveUnsupported = true
            UserDefaults.standard.set(true, forKey: "spaceMoveUnsupported")
            NSLog("[HopTab] Windows-to-Space move failed — falling back to hide-based profile switching")
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

        // terminate() is only a request — apps with unsaved-changes dialogs (or
        // that refused outright) linger. Check back shortly and tell the user.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self else { return }
            let lingering = profile.pinnedApps.filter { $0.isRunning }.count
            guard lingering > 0 else { return }
            let message = lingering == 1
                ? "1 app didn't close — check for unsaved changes"
                : "\(lingering) apps didn't close — check for unsaved changes"
            self.toastController.show(icon: "exclamationmark.circle", message: message)
        }
    }

    /// Relaunch all apps in a profile and restore their window positions.
    func restoreSession(profileId: UUID) {
        guard let profile = store.profiles.first(where: { $0.id == profileId }) else { return }

        // Cancel any pending work from a previous restore
        cancelPendingProfileWork()

        // Same Stage Manager rationale as switchToProfile — block space-driven
        // re-entry while we launch apps and reposition windows.
        isApplyingProfile = true

        // Resolve launch options per app. skipOnRestore apps stay pinned (in the
        // switcher) but are excluded from launch and positioning entirely.
        let optionsFor: (String) -> LaunchOptions? = { [store = self.store] bundleId in
            store.launchOptions(profileId: profileId, bundleId: bundleId)
        }
        let launchable = profile.pinnedApps.filter { !(optionsFor($0.bundleIdentifier)?.skipOnRestore ?? false) }

        // Group by launchPriority: lower first, nil = default/last group.
        // Apps launch in parallel within a group; the next group waits until the
        // previous group's apps are all ready (or timed out), plus launchDelay.
        let prioritized = Dictionary(grouping: launchable) { optionsFor($0.bundleIdentifier)?.launchPriority }
        var groups: [[PinnedApp]] = prioritized
            .compactMap { key, apps in key.map { ($0, apps) } }
            .sorted { $0.0 < $1.0 }
            .map { $0.1 }
        if let defaultGroup = prioritized[nil] { groups.append(defaultGroup) }

        // Check if this profile has a layout binding — use that instead of snapshot
        let layoutWork: (binding: LayoutBinding, template: LayoutTemplate)?
        if let binding = profile.layoutBinding,
           let template = store.allTemplates.first(where: { $0.id == binding.templateId }),
           !binding.zoneAssignments.isEmpty {
            layoutWork = (binding, template)
        } else {
            layoutWork = nil
        }
        let snapshot = layoutWork == nil ? store.snapshot(for: profileId) : nil

        // Readiness-driven restore: instead of blind fixed delays (which skip
        // slow-launching apps and revert user adjustments with a second pass),
        // poll each app every 0.5s (30s cap per group) until it exposes an AX
        // window, position it as soon as it's ready, then advance to the next
        // priority group. All timers route through scheduleProfileWork so a
        // display change or new profile switch cancels everything cleanly.
        var deadline = Date().addingTimeInterval(30)
        var pending = Set<String>()          // current group's unready apps
        var groupIndex = -1                  // advanced before each group starts
        var restoredApps = Set<String>()
        var urlsOpened = Set<String>()

        // Open an app's configured URLs at most once per restore, best-effort.
        let openURLsIfNeeded: (String) -> Void = { bundleId in
            guard !urlsOpened.contains(bundleId),
                  let urls = optionsFor(bundleId)?.openURLs, !urls.isEmpty else { return }
            urlsOpened.insert(bundleId)
            SessionSnapshotService.openURLs(urls, inApp: bundleId)
        }

        // Runs once every group is done (all apps ready or timed out).
        let finish: () -> Void = { [weak self] in
            guard let self else { return }
            if let observer = self.restoreLaunchObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
                self.restoreLaunchObserver = nil
            }
            let skipped = Set(profile.pinnedApps.map(\.bundleIdentifier))
                .subtracting(launchable.map(\.bundleIdentifier))
            if let layoutWork {
                _ = LayoutService.applyLayout(binding: layoutWork.binding, template: layoutWork.template, profile: profile)
            } else if let snapshot {
                // Cleanup: position apps the poll never caught, re-assert z-order —
                // without re-applying frames of already-restored apps, and never
                // touching skipOnRestore apps.
                SessionSnapshotService.finalizeRestore(snapshot, for: profile, skipping: restoredApps.union(skipped))
            }
            // Move apps to assigned displays now that windows exist
            self.applyDisplayAssignments(for: profile, initialDelay: 0.5)
            // Release space-change suppression after the display-assignment waves
            self.scheduleProfileWork(delay: 3.0) { [weak self] in
                self?.finishProfileApply()
            }
        }

        // Forward declaration so complete/pollReadiness can advance groups.
        var startNextGroup: (() -> Void)!

        let complete: (String) -> Void = { bundleId in
            guard pending.remove(bundleId) != nil else { return }
            // Ready or timed out — open its URLs if it's running at all
            if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty {
                openURLsIfNeeded(bundleId)
            }
            if pending.isEmpty { startNextGroup() }
        }

        func pollReadiness(_ bundleId: String) {
            guard pending.contains(bundleId) else { return }
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first,
               SessionSnapshotService.appHasWindows(running) {
                // Position this app's windows immediately rather than waiting for
                // one global pass (layout bindings apply once, when all are ready)
                if let snapshot {
                    SessionSnapshotService.restoreWindows(from: snapshot, bundleIdentifier: bundleId)
                    restoredApps.insert(bundleId)
                }
                complete(bundleId)
                return
            }
            guard Date() < deadline else {
                complete(bundleId) // never became ready — skip it
                return
            }
            scheduleProfileWork(delay: 0.5) { pollReadiness(bundleId) }
        }

        startNextGroup = { [weak self] in
            guard let self else { return }
            groupIndex += 1
            guard groupIndex < groups.count else {
                finish()
                return
            }
            let group = groups[groupIndex]
            // 30s readiness cap per group, extended by the largest launchDelay
            // so a staggered app still gets its full readiness window.
            let maxDelay = groupIndex == 0 ? 0 : group
                .compactMap { optionsFor($0.bundleIdentifier)?.launchDelay }
                .max() ?? 0
            deadline = Date().addingTimeInterval(30 + max(0, maxDelay))
            pending = Set(group.map(\.bundleIdentifier))

            for app in group {
                let delay = groupIndex == 0 ? 0 : max(0, optionsFor(app.bundleIdentifier)?.launchDelay ?? 0)
                let launch = {
                    SessionSnapshotService.launchApps([app])
                    pollReadiness(app.bundleIdentifier)
                }
                if delay > 0 {
                    self.scheduleProfileWork(delay: delay) { launch() }
                } else {
                    launch()
                }
            }
        }

        // Fast path: an app finishing launch kicks its readiness poll immediately
        restoreLaunchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { note in
            guard let bundleId = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            Task { @MainActor in pollReadiness(bundleId) }
        }

        startNextGroup()

        // Show sticky note if set
        if let note = profile.stickyNote, !note.isEmpty {
            stickyNoteController.show(profileName: profile.name, note: note)
        }
    }

    /// Move apps with display assignments to their target screens.
    private func applyDisplayAssignments(for profile: Profile, initialDelay: TimeInterval = 0.5) {
        let appsWithDisplays = profile.pinnedApps.filter { $0.assignedDisplay != nil }
        guard !appsWithDisplays.isEmpty, NSScreen.screens.count > 1 else { return }

        let moveApps = {
            for app in appsWithDisplays {
                if let display = app.assignedDisplay {
                    LayoutService.moveAppToDisplay(bundleIdentifier: app.bundleIdentifier, displayName: display)
                }
            }
        }

        // Try twice — first after layout settles, second for slow apps
        scheduleProfileWork(delay: initialDelay) { moveApps() }
        scheduleProfileWork(delay: initialDelay + 2.0) { moveApps() }
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
        // Space-change events during/just-after a profile switch are almost
        // certainly Stage Manager's own stage transitions — but a genuine user
        // change can land in the same window, so remember it and re-evaluate
        // when the apply completes instead of dropping it.
        guard !isApplyingProfile else {
            pendingSpaceChangeDuringApply = true
            return
        }
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
        if let observer = restoreLaunchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = screenParamsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        hotkeyService.stop()
    }
}
