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
    /// User-added ⌥K rows (Settings → Command Palette).
    let customCommands = CustomCommandsStore()
    /// The app that had focus when ⌥K opened; paste commands go back to it.
    private var commandPaletteFrontmostApp: NSRunningApplication?
    private let stickyNoteController = StickyNoteOverlayController()
    private let toastController = ToastOverlayController()

    @Published private(set) var selectedIndex: Int = 0
    @Published private(set) var isSwitcherVisible: Bool = false
    @Published var runningApps: [NSRunningApplication] = []
    @Published var installedApps: [InstalledAppsService.AppInfo] = []
    @Published private(set) var isLoadingInstalledApps = false

    /// Mirrors `PermissionsService.isTrusted`. Views observing only `AppState`
    /// never saw the nested object change, so permission banners did not
    /// disappear when the user granted access.
    @Published private(set) var isAccessibilityTrusted = false

    /// True while macOS secure input is on (a password field, or Terminal's
    /// Secure Keyboard Entry). The event tap receives no keys in that state,
    /// so shortcuts stop working and used to do so silently.
    @Published private(set) var isSecureInputActive = false
    @Published var recentAppFirst: Bool = UserDefaults.standard.bool(forKey: "recentAppFirst") {
        didSet {
            UserDefaults.standard.set(recentAppFirst, forKey: "recentAppFirst")
        }
    }

    /// When on, ⌘Tab opens HopTab's all-apps switcher (pinned group first,
    /// every other running app after) instead of the macOS one. The
    /// configurable preset (⌥Tab by default) stays the pinned-only switcher.
    @Published var replaceCommandTab: Bool = UserDefaults.standard.bool(forKey: "replaceCommandTab") {
        didSet {
            UserDefaults.standard.set(replaceCommandTab, forKey: "replaceCommandTab")
            applyAllAppsTrigger()
        }
    }

    /// When on, releasing the switcher on an app with two or more windows on
    /// this Space opens the window picker. Off by default: the picker swallows
    /// every key until a window is chosen, which reads as a nag on browsers
    /// that always have several windows. Space in the switcher still drills in.
    @Published var askWhichWindow: Bool = UserDefaults.standard.bool(forKey: "askWhichWindow") {
        didSet {
            UserDefaults.standard.set(askWhichWindow, forKey: "askWhichWindow")
        }
    }

    // MARK: Command palette (⌥K)

    /// ⌥K opens a search over workspaces, apps, Chrome tabs/bookmarks/history
    /// and HopTab actions. Off → the key goes to the focused app.
    @Published var commandPaletteEnabled: Bool =
        UserDefaults.standard.object(forKey: "commandPaletteEnabled") == nil
            ? true : UserDefaults.standard.bool(forKey: "commandPaletteEnabled") {
        didSet {
            UserDefaults.standard.set(commandPaletteEnabled, forKey: "commandPaletteEnabled")
            applyCommandPaletteTrigger()
        }
    }

    /// Custom palette shortcut; nil means the default ⌥K.
    @Published var commandPaletteShortcut: CustomShortcut? = {
        guard let data = UserDefaults.standard.data(forKey: "commandPaletteShortcut") else { return nil }
        return try? JSONDecoder().decode(CustomShortcut.self, from: data)
    }() {
        didSet {
            if let c = commandPaletteShortcut, let data = try? JSONEncoder().encode(c) {
                UserDefaults.standard.set(data, forKey: "commandPaletteShortcut")
            } else {
                UserDefaults.standard.removeObject(forKey: "commandPaletteShortcut")
            }
            applyCommandPaletteTrigger()
        }
    }

    /// Include Google Chrome's open tabs, bookmarks and history in ⌥K.
    /// The first tab read asks macOS for Automation access to Chrome.
    @Published var commandPaletteIncludesChrome: Bool =
        UserDefaults.standard.object(forKey: "commandPaletteIncludesChrome") == nil
            ? true : UserDefaults.standard.bool(forKey: "commandPaletteIncludesChrome") {
        didSet {
            UserDefaults.standard.set(commandPaletteIncludesChrome, forKey: "commandPaletteIncludesChrome")
            if !commandPaletteIncludesChrome { commandPaletteIndex.invalidateChromeCache() }
        }
    }

    static let defaultCommandPaletteShortcut = CustomShortcut(
        modifierFlagsRawValue: CGEventFlags.maskAlternate.rawValue,
        keyCode: Int64(kVK_ANSI_K)
    )

    /// The palette shortcut in effect, for display.
    var effectiveCommandPaletteShortcut: CustomShortcut {
        commandPaletteShortcut ?? Self.defaultCommandPaletteShortcut
    }

    private let commandPaletteController = CommandPaletteController()
    let commandPaletteIndex = CommandPaletteIndex()
    @Published private(set) var isCommandPaletteVisible = false

    /// Which list the open switcher is showing.
    private var switcherShowsAllApps = false

    /// Bundle identifiers, most recently activated first. Drives the order of
    /// the "other running" group. Capped so it never grows unbounded.
    private var recentActivationOrder: [String] = []

    /// The list the switcher is currently showing. Built when the switcher
    /// opens and rebuilt in place after a pin/unpin, so indices stay valid
    /// for the whole gesture.
    private var switcherEntries: [SwitcherEntry] = []
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
    @Published private(set) var isApplyingProfile: Bool = false
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

        // Migration: the old "⌘Tab" preset meant the pinned switcher lived on
        // ⌘Tab. That is now the all-apps switcher's job, so flip the flag and
        // put the pinned switcher back on ⌥Tab.
        if case .preset(.commandTab) = appShortcutSelection {
            replaceCommandTab = true
            appShortcutSelection = .preset(.optionTab)
            selectedPreset = .optionTab
        }

        applyAppShortcut()
        applyProfileShortcut()
        applyAllAppsTrigger()
        applyCommandPaletteTrigger()
        setupCommandPalette()
        syncProfileHotkeys()
        refreshRunningApps()
        observeWorkspace()
        setupHotkeyCallbacks()
        setupSnapFailureReporting()
        setupStateRepublishing()

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

    private func applyAllAppsTrigger() {
        hotkeyService.configureAllAppsSwitcher(
            replaceCommandTab ? (modifierFlag: .maskCommand, keyCode: Int64(kVK_Tab)) : nil
        )
    }

    private func applyCommandPaletteTrigger() {
        guard commandPaletteEnabled else {
            hotkeyService.configureCommandPalette(nil)
            return
        }
        let shortcut = effectiveCommandPaletteShortcut
        hotkeyService.configureCommandPalette((shortcut.modifierFlags, shortcut.keyCode))
    }

    private func applyProfileShortcut() {
        let modFlag: CGEventFlags
        let keyCode: Int64
        let modName: String
        let keyName: String

        if isCustomProfileShortcut, let c = customProfileShortcut {
            modFlag = c.modifierFlags
            keyCode = c.keyCode
            // `modifierName` is glyph-prefixed ("⌥Option") for the recorder;
            // the menu header already spells the word, so drop the glyphs.
            modName = c.modifierName.filter { !"\u{2303}\u{2325}\u{21E7}\u{2318}".contains($0) }
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
            self?.showSwitcher(allApps: false)
        }

        hotkeyService.onAllAppsSwitcherActivated = { [weak self] in
            self?.showSwitcher(allApps: true)
        }

        hotkeyService.onCommandPaletteActivated = { [weak self] in
            self?.toggleCommandPalette()
        }

        hotkeyService.onCreateWorkspaceWithHighlighted = { [weak self] in
            self?.createWorkspaceWithHighlightedApp()
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
            DispatchQueue.main.async { self?.showSwitcher(allApps: false) }
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

        hotkeyService.onToggleHighlightedInProfileSlot = { [weak self] slot in
            self?.toggleHighlightedApp(inProfileSlot: slot)
        }

        hotkeyService.onToggleHighlightedInActiveProfile = { [weak self] in
            self?.toggleHighlightedAppInActiveProfile()
        }

        hotkeyService.onUnpinHighlighted = { [weak self] in
            self?.unpinHighlightedApp()
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
        OnboardingProgress.bump(switcherShowsAllApps ? .allAppsSwitcher : .workspaceSwitcher)
    }

    private func buildSwitcherEntries() -> [SwitcherEntry] {
        // `runningApps` is kept current by launch/terminate notifications;
        // asking NSWorkspace again here is one IPC per process on the
        // keystroke path, ~20 ms with a busy Mac.
        SwitcherEntry.build(
            pinned: store.apps,
            running: runningApps,
            recentOrder: recentActivationOrder,
            includeRunning: switcherShowsAllApps,
            excluding: [Bundle.main.bundleIdentifier ?? ""]
        )
    }

    private var switcherContext: SwitcherProfileContext {
        SwitcherProfileContext(
            profiles: store.profiles,
            activeProfileId: store.activeProfileId,
            canAddWorkspace: store.canAddProfile
        )
    }

    /// Rebuild the list after a pin/unpin, keeping the highlight on the same
    /// app even though it just moved between groups.
    private func rebuildSwitcherEntries(keepingSelectionOn bundleId: String) {
        switcherEntries = buildSwitcherEntries()
        if let idx = switcherEntries.firstIndex(where: { $0.app.bundleIdentifier == bundleId }) {
            selectedIndex = idx
        } else {
            selectedIndex = min(selectedIndex, max(0, switcherEntries.count - 1))
        }
        overlayController.update(entries: switcherEntries, selectedIndex: selectedIndex, context: switcherContext)
    }

    private var highlightedEntry: SwitcherEntry? {
        guard isSwitcherVisible, switcherEntries.indices.contains(selectedIndex) else { return nil }
        return switcherEntries[selectedIndex]
    }

    private func showSwitcher(allApps: Bool) {
        switcherShowsAllApps = allApps
        switcherEntries = buildSwitcherEntries()

        selectedIndex = 0
        if switcherEntries.count > 1 {
            selectedIndex = 1
        }

        isSwitcherVisible = true
        overlayController.showHints = shouldShowHints
        overlayController.show(entries: switcherEntries, selectedIndex: selectedIndex, context: switcherContext)
        incrementSwitcherCount()
    }

    private func cycleForward() {
        guard !switcherEntries.isEmpty else { return }
        selectedIndex = (selectedIndex + 1) % switcherEntries.count
        overlayController.update(entries: switcherEntries, selectedIndex: selectedIndex, context: switcherContext)
    }

    private func cycleBackward() {
        guard !switcherEntries.isEmpty else { return }
        selectedIndex = (selectedIndex - 1 + switcherEntries.count) % switcherEntries.count
        overlayController.update(entries: switcherEntries, selectedIndex: selectedIndex, context: switcherContext)
    }

    private func dismissAndActivate() {
        guard isSwitcherVisible else { return }
        guard let entry = highlightedEntry else {
            cancelSwitcher()
            return
        }

        let selectedApp = entry.app
        overlayController.dismiss()
        isSwitcherVisible = false

        // Activate the app first so its windows come forward
        AppSwitcherService.activate(selectedApp)
        if recentAppFirst, entry.isPinned {
            store.moveToFront(bundleIdentifier: selectedApp.bundleIdentifier)
        }

        // If asked to, and the app has 2+ windows on the current Space, show
        // the window picker. Enumeration is Accessibility work, so it runs off
        // the main thread — this path is reached from the event-tap callback
        // on every Option+Tab.
        if askWhichWindow, let running = selectedApp.runningApplication {
            AppSwitcherService.enumerateWindows(of: running) { [weak self] allWindows in
                guard let self else { return }
                let windows = AppSwitcherService.windowsOnCurrentSpace(allWindows)
                if windows.count >= 2 {
                    self.showWindowPicker(app: selectedApp, windows: windows)
                }
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
        guard let entry = highlightedEntry else { return }

        let selectedApp = entry.app
        guard let running = selectedApp.runningApplication else { return }

        AppSwitcherService.enumerateWindows(of: running) { [weak self] allWindows in
            guard let self else { return }
            let windows = AppSwitcherService.windowsOnCurrentSpace(allWindows)
            // No windows on this Space — leave the switcher exactly as it was.
            guard !windows.isEmpty else { return }

            AppSwitcherService.activate(selectedApp)
            if self.recentAppFirst, entry.isPinned {
                self.store.moveToFront(bundleIdentifier: selectedApp.bundleIdentifier)
            }

            self.overlayController.dismiss()
            self.isSwitcherVisible = false

            self.showWindowPicker(app: selectedApp, windows: windows)
        }
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
        OnboardingProgress.bump(.workspacePicker)
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
        guard let entry = highlightedEntry else { return }
        entry.app.runningApplication?.terminate()
        // Pinned apps stay listed (not running); an unpinned app disappears.
        if entry.isPinned {
            if switcherEntries.count > 1 {
                selectedIndex = (selectedIndex + 1) % switcherEntries.count
                overlayController.update(entries: switcherEntries, selectedIndex: selectedIndex, context: switcherContext)
            } else {
                cancelSwitcher()
            }
        } else {
            switcherEntries.remove(at: selectedIndex)
            if switcherEntries.isEmpty {
                cancelSwitcher()
            } else {
                selectedIndex = min(selectedIndex, switcherEntries.count - 1)
                overlayController.update(entries: switcherEntries, selectedIndex: selectedIndex, context: switcherContext)
            }
        }
    }

    private func hideHighlightedApp() {
        guard let entry = highlightedEntry else { return }
        entry.app.runningApplication?.hide()
        // Move to next app
        if switcherEntries.count > 1 {
            selectedIndex = (selectedIndex + 1) % switcherEntries.count
            overlayController.update(entries: switcherEntries, selectedIndex: selectedIndex, context: switcherContext)
        }
    }

    private func minimizeHighlightedApp() {
        guard let entry = highlightedEntry else { return }
        if let running = entry.app.runningApplication {
            AppSwitcherService.minimizeFirstWindow(of: running)
        }
        // Move to next app
        if switcherEntries.count > 1 {
            selectedIndex = (selectedIndex + 1) % switcherEntries.count
            overlayController.update(entries: switcherEntries, selectedIndex: selectedIndex, context: switcherContext)
        }
    }

    // MARK: - Pin / unpin from inside the switcher

    /// 1–9: toggle the highlighted app's membership in the Nth profile.
    private func toggleHighlightedApp(inProfileSlot slot: Int) {
        guard let entry = highlightedEntry, store.profiles.indices.contains(slot) else { return }
        let profile = store.profiles[slot]
        let pinned = store.togglePin(
            bundleIdentifier: entry.app.bundleIdentifier,
            displayName: entry.app.displayName,
            inProfile: profile.id
        )
        overlayController.flashPinFeedback(pinned: pinned, profileName: profile.name)
        rebuildSwitcherEntries(keepingSelectionOn: entry.app.bundleIdentifier)
    }

    /// P: toggle the highlighted app in the active profile.
    private func toggleHighlightedAppInActiveProfile() {
        guard let activeId = store.activeProfileId,
              let slot = store.profiles.firstIndex(where: { $0.id == activeId })
        else { return }
        toggleHighlightedApp(inProfileSlot: slot)
    }

    /// N: a new workspace containing just the highlighted app. Does not
    /// activate it — the user is mid-switch; the new workspace shows up in
    /// the digit map immediately.
    private func createWorkspaceWithHighlightedApp() {
        guard let entry = highlightedEntry else { return }
        guard store.canAddProfile else {
            overlayController.flashPinFeedback(message: "Workspace limit reached \u{2014} Pro removes it")
            return
        }
        let existing = Set(store.profiles.map(\.name))
        var n = store.profiles.count + 1
        var name = "Workspace \(n)"
        while existing.contains(name) { n += 1; name = "Workspace \(n)" }
        store.addProfile(name: name)
        guard let created = store.profiles.last else { return }
        store.add(entry.app, toProfile: created.id)
        overlayController.flashPinFeedback(message: "Created \(name) with \(entry.app.displayName)")
        rebuildSwitcherEntries(keepingSelectionOn: entry.app.bundleIdentifier)
    }

    /// Delete: remove the highlighted app from the active profile. Does
    /// nothing for an app that is not pinned there — Delete must never add.
    private func unpinHighlightedApp() {
        guard let entry = highlightedEntry, entry.isPinned, let activeId = store.activeProfileId else { return }
        store.remove(bundleIdentifier: entry.app.bundleIdentifier, fromProfile: activeId)
        overlayController.flashPinFeedback(pinned: false, profileName: store.activeProfile?.name ?? "")
        rebuildSwitcherEntries(keepingSelectionOn: entry.app.bundleIdentifier)
    }

    // MARK: - Command palette

    private func setupCommandPalette() {
        let vm = commandPaletteController.viewModel
        // Build the palette window once launch has settled, not on first use.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self else { return }
            self.overlayController.prewarm()
            if self.commandPaletteEnabled { self.commandPaletteController.prewarm() }
        }
        vm.onClose = { [weak self] in self?.dismissCommandPalette() }
        vm.onPerform = { [weak self] item, alternate in
            self?.performCommandPaletteAction(item, alternate: alternate)
        }
        vm.onSaveAsCommand = { [weak self] query in
            guard let self else { return }
            self.dismissCommandPalette()
            SettingsNavigation.shared.pendingCommandDraft = query
            SettingsNavigation.open(.palette)
        }
        vm.onCloseTab = { [weak self] item in
            guard let self, case .activateChromeTab(let w, let t) = item.action else { return }
            DispatchQueue.global(qos: .userInitiated).async {
                ChromeDataService.closeTab(windowIndex: w, tabIndex: t)
                DispatchQueue.main.async { self.refreshCommandPaletteIndex() }
            }
        }
        commandPaletteIndex.$items
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in self?.commandPaletteController.viewModel.setItems(items) }
            .store(in: &cancellables)
        commandPaletteIndex.$isLoadingChrome
            .receive(on: DispatchQueue.main)
            .sink { [weak self] loading in self?.commandPaletteController.viewModel.isLoading = loading }
            .store(in: &cancellables)
    }

    func toggleCommandPalette() {
        if commandPaletteController.isVisible {
            dismissCommandPalette()
        } else {
            showCommandPalette()
        }
    }

    func showCommandPalette() {
        // Never over an open switcher gesture.
        guard !isSwitcherVisible, !isProfileSwitcherVisible, !isWindowPickerVisible else { return }
        ensureInstalledAppsLoaded()
        // Capture focus *before* the panel takes it: this is what makes ⌥K
        // in Chrome show tabs first and ⌥K in VSCodium show projects first.
        let mine = Bundle.main.bundleIdentifier
        let frontApp = NSWorkspace.shared.frontmostApplication
        let front = frontApp?.bundleIdentifier
        commandPaletteFrontmostApp = front == mine ? nil : frontApp
        commandPaletteController.viewModel.frontmostBundleIdentifier = front == mine ? nil : front
        refreshCommandPaletteIndex(frontmostApp: front == mine ? nil : frontApp)
        commandPaletteController.viewModel.shortcutHint = effectiveCommandPaletteShortcut.displayName
        commandPaletteController.show()
        isCommandPaletteVisible = true
        OnboardingProgress.bump(.commandPalette)
    }

    func dismissCommandPalette() {
        commandPaletteController.dismiss()
        isCommandPaletteVisible = false
    }

    private func refreshCommandPaletteIndex(frontmostApp: NSRunningApplication? = nil) {
        commandPaletteIndex.refresh(with: CommandPaletteIndex.Context(
            profiles: store.profiles,
            activeProfileId: store.activeProfileId,
            installedApps: installedApps,
            runningApps: runningApps,
            recentOrder: recentActivationOrder,
            canAddWorkspace: store.canAddProfile,
            includeChrome: commandPaletteIncludesChrome,
            frontmostApp: frontmostApp,
            customCommands: customCommands.commands
        ))
    }

    private func performCommandPaletteAction(_ item: CommandPaletteItem, alternate: Bool) {
        dismissCommandPalette()
        switch item.action {
        case .switchWorkspace(let id):
            activateProfile(id: id)
        case .activateApp(let app):
            AppSwitcherService.activate(app)
        case .activateChromeTab(let w, let t):
            DispatchQueue.global(qos: .userInitiated).async {
                ChromeDataService.activateTab(windowIndex: w, tabIndex: t)
            }
        case .openURL(let url, let profileDirectory):
            if alternate {
                ChromeDataService.open(url, inProfileDirectory: profileDirectory, newWindow: true)
            } else {
                ChromeDataService.open(url, inProfileDirectory: profileDirectory)
            }
        case .openProject(let url, let editorBundleId):
            if let editor = EditorProjectsService.editors.first(where: { $0.bundleIdentifier == editorBundleId }) {
                EditorProjectsService.open(.init(name: url.lastPathComponent, url: url, editor: editor, lastOpened: 0))
            } else {
                NSWorkspace.shared.open(url)
            }
        case .switchChromeProfile(let directory, let name):
            ChromeDataService.switchToProfile(directory: directory, name: name)
        case .switchSafariProfile(let name):
            SafariProfilesService.switchToProfile(name: name)
        case .selectNativeTab(let bundleId, let windowID, let index):
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                // Activation (and the palette's own key-window handoff) raise
                // the app's current key window, i.e. the old tab. Let that
                // settle before pressing the new tab, or it is undone.
                app.activate(options: .activateIgnoringOtherApps)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    AppSwitcherService.selectNativeTab(of: app, windowID: windowID, index: index)
                }
            }
        case .raiseWindow(let bundleId, let windowID):
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first {
                app.activate(options: .activateIgnoringOtherApps)
                AppSwitcherService.raiseWindow(of: app, windowID: windowID)
            }
        case .snap(let direction):
            // Give focus back to the app that had it before the panel.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.performSnapAction(direction)
            }
        case .newWorkspaceFromRunning:
            _ = createProfileFromRunningApps()
        case .openSettings:
            NSApp.sendAction(#selector(AppDelegate.openSettings(_:)), to: nil, from: nil)
        case .openOnboarding:
            NSApp.sendAction(#selector(AppDelegate.showOnboarding(_:)), to: nil, from: nil)
        case .runCustomCommand(let id):
            guard let command = customCommands.command(id: id) else { return }
            let front = commandPaletteFrontmostApp
            // Let the panel finish handing key focus back before keys fly.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                CustomCommandRunner.run(command, frontmostBefore: front)
            }
        }
    }

    func refreshRunningApps() {
        // `localizedName` is an IPC round trip; read it once per app, not
        // once per comparison.
        runningApps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { ($0, $0.localizedName ?? "") }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Load the installed-app list off the main thread, once, on demand.
    ///
    /// This used to run synchronously in `init`, scanning four directories and
    /// loading a full-resolution icon for every installed app before the
    /// menu-bar item existed — 0.3-1.5s of launch for a list whose only
    /// consumer is the Settings app picker.
    func ensureInstalledAppsLoaded() {
        guard installedApps.isEmpty, !isLoadingInstalledApps else { return }
        isLoadingInstalledApps = true
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = InstalledAppsService.discoverInstalledApps()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.installedApps = apps
                self.isLoadingInstalledApps = false
            }
        }
    }

    /// Force a rescan (e.g. after the user installs an app while Settings is open).
    func refreshInstalledApps() {
        isLoadingInstalledApps = true
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = InstalledAppsService.discoverInstalledApps()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.installedApps = apps
                self.isLoadingInstalledApps = false
            }
        }
    }

    /// Release the picker's icon memory when Settings closes.
    func releaseInstalledAppsCache() {
        InstalledAppsService.flushIconCache()
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

        // Most-recently-used order for the switcher's "other running" group.
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            recentActivationOrder = [front]
        }
        let activateObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let bundleId = app.bundleIdentifier
            else { return }
            Task { @MainActor in
                self?.noteActivation(of: bundleId)
            }
        }
        workspaceObservers.append(activateObserver)

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

    private func noteActivation(of bundleId: String) {
        recentActivationOrder.removeAll { $0 == bundleId }
        recentActivationOrder.insert(bundleId, at: 0)
        if recentActivationOrder.count > 64 { recentActivationOrder.removeLast() }
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
        OnboardingProgress.bump(.snap)
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
            // Pro tracks every window move; the free tier tracks snaps. Either
            // way Ctrl+Opt+Shift+Z must do something — it ships as a default
            // binding and used to be a dead key without Pro.
            if let provider = ProServiceRegistry.shared.provider, provider.canWindowRedo {
                provider.windowRedo()
            } else {
                LayoutService.redoSnap()
            }
        case .cycleNext:
            LayoutService.snapFrontmostCycle(forward: true)
        case .cyclePrevious:
            LayoutService.snapFrontmostCycle(forward: false)
        default:
            LayoutService.snapFrontmost(to: direction)
        }
    }



    /// Republish nested/opaque state that views need, so nothing has to poll.
    private func setupStateRepublishing() {
        isAccessibilityTrusted = permissions.isTrusted
        permissions.$isTrusted
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] trusted in
                guard let self else { return }
                self.isAccessibilityTrusted = trusted
                // The tap caches the trust flag to keep an XPC call off the
                // input path; tell it the moment the grant changes.
                self.hotkeyService.refreshTrust()
            }
            .store(in: &cancellables)

        isSecureInputActive = hotkeyService.isSecureInputActive
        hotkeyService.onSecureInputChange = { [weak self] active in
            self?.isSecureInputActive = active
        }
    }

    /// Nudge SwiftUI after Pro focus/Pomodoro transitions, which are otherwise
    /// invisible to observers of `AppState`.
    func proSessionStateDidChange() {
        objectWillChange.send()
    }

    // MARK: - Snap feedback

    /// Snaps used to fail silently: no permission, no window, an app that
    /// refuses to resize. The keystroke did nothing and said nothing.
    private func setupSnapFailureReporting() {
        LayoutService.onSnapFailure = { [weak self] failure, appName in
            guard let self else { return }
            switch failure {
            case .notTrusted:
                self.toastController.show(
                    icon: "exclamationmark.triangle.fill",
                    message: "Grant Accessibility in System Settings"
                )
            case .noFocusedApp:
                self.toastController.show(icon: "macwindow.badge.plus", message: failure.message)
            case .noSnappableWindow:
                let name = appName.map { "\($0) has no snappable window" }
                self.toastController.show(
                    icon: "macwindow.badge.plus",
                    message: name ?? failure.message
                )
            case .noScreen:
                self.toastController.show(icon: "display.trianglebadge.exclamationmark", message: failure.message)
            case .windowRefusedResize:
                let name = appName.map { "\($0) refused to resize" }
                self.toastController.show(
                    icon: "exclamationmark.circle",
                    message: name ?? failure.message
                )
            }
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
        // Piggyback the tap watchdog on this existing 30s tick rather than
        // adding a timer: re-enables a tap macOS disabled, refreshes the
        // cached trust flag, and updates the secure-input state.
        hotkeyService.verifyTapAlive()

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
        case "settings":
            // hoptab://settings/calendar — section names match the sidebar.
            let section = HopSettingsSection.allCases.first {
                $0.rawValue.lowercased() == (argument ?? "").lowercased()
                    || $0.deepLinkName == (argument ?? "").lowercased()
            }
            SettingsNavigation.open(section ?? SettingsNavigation.shared.section ?? .workspaces)
        default:
            break
        }
    }

    // MARK: - Session-Aware Profile Switching

    /// Public entry point for all UI-triggered profile switches.
    /// Menu bar "New workspace from what's open": a profile pinned with the
    /// regular apps running right now, most recently used first, then made
    /// active. Returns the new profile's id, or nil when the free limit holds.
    @discardableResult
    /// Running regular apps, most recently used first, that a new workspace
    /// could pin. HopTab and the Finder are left out.
    func runningAppCandidates() -> [NSRunningApplication] {
        let mine = Bundle.main.bundleIdentifier ?? ""
        let rank = Dictionary(uniqueKeysWithValues: recentActivationOrder.enumerated().map { ($1, $0) })
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != mine && $0.bundleIdentifier != "com.apple.finder" }
            .sorted { (rank[$0.bundleIdentifier ?? ""] ?? Int.max) < (rank[$1.bundleIdentifier ?? ""] ?? Int.max) }
    }

    /// Create a workspace pinned with exactly `bundleIdentifiers`, named
    /// `name` (or the next free "Workspace N" when blank), and switch to it.
    @discardableResult
    func createProfile(named name: String, bundleIdentifiers: [String]) -> UUID? {
        guard store.canAddProfile else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let finalName: String
        if trimmed.isEmpty {
            let existing = Set(store.profiles.map(\.name))
            var n = store.profiles.count + 1
            var candidate = "Workspace \(n)"
            while existing.contains(candidate) { n += 1; candidate = "Workspace \(n)" }
            finalName = candidate
        } else {
            finalName = trimmed
        }
        store.addProfile(name: finalName)
        guard let profile = store.profiles.last else { return nil }
        let running = Dictionary(
            NSWorkspace.shared.runningApplications.compactMap { app in app.bundleIdentifier.map { ($0, app) } },
            uniquingKeysWith: { first, _ in first }
        )
        for bundleId in bundleIdentifiers {
            let display = running[bundleId]?.localizedName ?? bundleId
            store.add(PinnedApp(bundleIdentifier: bundleId, displayName: display, sortOrder: 0), toProfile: profile.id)
        }
        store.setActiveProfile(id: profile.id)
        return profile.id
    }

    func createProfileFromRunningApps() -> UUID? {
        guard store.canAddProfile else { return nil }
        let existing = Set(store.profiles.map(\.name))
        var n = store.profiles.count + 1
        var name = "Workspace \(n)"
        while existing.contains(name) { n += 1; name = "Workspace \(n)" }
        store.addProfile(name: name)
        guard let profile = store.profiles.last else { return nil }

        let mine = Bundle.main.bundleIdentifier ?? ""
        let rank = Dictionary(uniqueKeysWithValues: recentActivationOrder.enumerated().map { ($1, $0) })
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != mine && $0.bundleIdentifier != "com.apple.finder" }
            .sorted { (rank[$0.bundleIdentifier ?? ""] ?? Int.max) < (rank[$1.bundleIdentifier ?? ""] ?? Int.max) }
            .prefix(8)
        for app in apps {
            guard let bundleId = app.bundleIdentifier else { continue }
            store.add(
                PinnedApp(bundleIdentifier: bundleId, displayName: app.localizedName ?? bundleId, sortOrder: 0),
                toProfile: profile.id
            )
        }
        store.setActiveProfile(id: profile.id)
        return profile.id
    }

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

            // 5c. Browser profile tied to this workspace: raise its window
            // after unhide, before layout so the window is there to place.
            if let browserProfile = incoming.browserProfile {
                self.scheduleProfileWork(delay: 0.1) { browserProfile.activate() }
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
        // Enumerating every pinned app's windows is Accessibility work. Done
        // serially on the main thread it stacked one bounded wait per app, so
        // a profile with several apps could stall input for seconds. Fan out,
        // then finish on main once every app has reported.
        let running = profile.pinnedApps.compactMap { $0.runningApplication }
        guard !running.isEmpty else { return }

        let group = DispatchGroup()
        let lock = NSLock()
        var windowIDs: [CGWindowID] = []

        for app in running {
            group.enter()
            AppSwitcherService.enumerateWindows(of: app) { windows in
                let ids = windows
                    .filter { !$0.isMinimized && $0.spaceID != spaceId }
                    .map(\.id)
                lock.lock()
                windowIDs.append(contentsOf: ids)
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self, !windowIDs.isEmpty else { return }
            self.finishMovingProfileWindows(windowIDs, toSpaceId: spaceId)
        }
    }

    private func finishMovingProfileWindows(_ windowIDs: [CGWindowID], toSpaceId spaceId: Int) {
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
        guard let entry = highlightedEntry else { return }
        LayoutService.snapApp(bundleIdentifier: entry.app.bundleIdentifier, to: direction)
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
