import SwiftUI
import ServiceManagement

// MARK: - Settings Window Controller

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(appState: AppState) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = SettingsRootView().environmentObject(appState)
        let hosting = NSHostingController(rootView: rootView)

        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.title = "HopTab Settings"
        w.toolbarStyle = .unified
        w.titlebarSeparatorStyle = .automatic
        w.contentMinSize = NSSize(width: 700, height: 480)
        w.setContentSize(NSSize(width: 760, height: 580))
        w.setFrameAutosaveName("HopTabSettings")
        if w.frame.width < 700 { w.center() }
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }
}

// MARK: - Sidebar Navigation

private enum SettingsSection: String, CaseIterable, Identifiable {
    case appsAndProfiles = "Apps & Profiles"
    case switcher = "Switcher"
    case windows = "Windows"
    case layouts = "Layouts"
    case automation = "Automation"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .appsAndProfiles: return "person.2"
        case .switcher: return "command"
        case .windows: return "macwindow"
        case .layouts: return "rectangle.split.3x1"
        case .automation: return "sparkles"
        case .about: return "info.circle"
        }
    }
}

// MARK: - Settings Root View

private struct SettingsRootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: SettingsSection? = .appsAndProfiles

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
        } detail: {
            Form {
                contentView
            }
            .formStyle(.grouped)
            .navigationTitle((selection ?? .appsAndProfiles).rawValue)
        }
        .frame(minWidth: 680, minHeight: 460)
    }

    @ViewBuilder
    private var contentView: some View {
        switch selection ?? .appsAndProfiles {
        case .appsAndProfiles:
            GeneralSection()
            PinnedAppsSection()
            ProfilesSection()
        case .switcher:
            ShortcutsSection()
        case .windows:
            SnappingSection()
            WindowRulesSection()
            WindowUndoSection()
            // DISABLED: Look & Feel (Focus Border / Focus Dimming / rice presets)
            // is commented out for this release — see ProBridge.swift.
            // LookAndFeelSection()
            AdvancedSpaceControlSection()
        case .layouts:
            LayoutsSection()
        case .automation:
            automationContent
        case .about:
            ProSection()
            AboutSection()
        }
    }

    @ViewBuilder
    private var automationContent: some View {
        if let provider = ProServiceRegistry.shared.provider {
            Section {
                provider.automationSectionView(profiles: appState.store.profiles.map { ProProfileInfo(id: $0.id, name: $0.name) })
            }
            Section {
                ScreenBreaksSection()
            }
            Section {
                DisplaysSection()
            }
        } else {
            Section("Automation") {
                Text("Pro features require HopTab Pro")
                    .foregroundStyle(.secondary)
                Link("Get HopTab Pro", destination: ProLinks.purchaseURL)
            }
        }
    }
}

// MARK: - General Section

private struct GeneralSection: View {
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var requiresApproval = SMAppService.mainApp.status == .requiresApproval
    @State private var registrationError: String?

    var body: some View {
        Section("General") {
            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) {
                    setLaunchAtLogin(launchAtLogin)
                }

            if requiresApproval {
                HStack(spacing: HopSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.hopCaption)
                    Text("macOS needs your approval to launch HopTab at login.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items Settings") {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                    .controlSize(.small)
                }
            }

            if let registrationError {
                Text(registrationError)
                    .font(.hopCaption)
                    .foregroundStyle(.red)
            }
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

// MARK: - Fuzzy Match Helper

private func fuzzyMatch(query: String, target: String) -> Bool {
    var queryIndex = query.lowercased().startIndex
    let lowerTarget = target.lowercased()
    let lowerQuery = query.lowercased()

    for char in lowerTarget {
        guard queryIndex < lowerQuery.endIndex else { return true }
        if char == lowerQuery[queryIndex] {
            queryIndex = lowerQuery.index(after: queryIndex)
        }
    }
    return queryIndex == lowerQuery.endIndex
}

// MARK: - Shared Profile Picker

private struct ActiveProfilePicker: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Picker("Profile", selection: Binding(
            get: { appState.store.activeProfileId },
            set: { newValue in
                if let id = newValue { appState.activateProfile(id: id) }
            }
        )) {
            ForEach(appState.store.profiles) { profile in
                Text(profile.name).tag(Optional(profile.id))
            }
        }
    }
}

// MARK: - Pinned Apps Section

private struct PinnedAppsSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var appSource: AppSource = .running

    enum AppSource: String, CaseIterable {
        case running = "Running"
        case allApps = "All Apps"
    }

    var body: some View {
        if appState.store.activeProfile != nil {
            Section {
                ActiveProfilePicker()
            }
        }

        Section {
            if appState.store.apps.isEmpty {
                VStack(spacing: HopSpacing.xs) {
                    Image(systemName: "pin")
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                    Text("No apps pinned yet")
                        .font(.hopSubheading)
                        .foregroundStyle(.secondary)
                    Text("Click the pin icon on any app below to add it")
                        .font(.hopCaption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 50)
            } else {
                List {
                    ForEach(appState.store.apps) { app in
                        HStack {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 24, height: 24)
                            Text(app.displayName)

                            // Display assignment picker
                            Picker("", selection: Binding(
                                get: { app.assignedDisplay },
                                set: { appState.store.setDisplayAssignment(bundleIdentifier: app.bundleIdentifier, displayName: $0) }
                            )) {
                                Text("Any").tag(String?.none)
                                ForEach(displayOptions, id: \.id) { option in
                                    HStack {
                                        Image(systemName: option.name.lowercased().contains("built-in") ? "laptopcomputer" : "display")
                                        Text(option.label)
                                    }
                                    .tag(String?.some(option.name))
                                }
                            }
                            .labelsHidden()
                            .controlSize(.mini)
                            .frame(width: 140)

                            Spacer()
                            Circle()
                                .fill(app.isRunning ? Color.green : Color.gray.opacity(0.3))
                                .frame(width: 8, height: 8)
                            Button(role: .destructive) {
                                appState.store.remove(bundleIdentifier: app.bundleIdentifier)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onMove { source, destination in
                        appState.store.move(from: source, to: destination)
                    }
                }
                .frame(minHeight: 100, maxHeight: 180)
            }
        } header: {
            Text("Pinned Apps")
        } footer: {
            Text("Pin the apps you use most. Use \(appState.appShortcutSelection.displayName) to cycle through only these apps instead of everything running. Drag to reorder.")
        }

        Section {
            Picker("Source", selection: $appSource) {
                ForEach(AppSource.allCases, id: \.self) { source in
                    Text(source.rawValue).tag(source)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: HopSpacing.xs) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Filter apps\u{2026}", text: $searchText)
                    .textFieldStyle(.plain)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if appSource == .running {
                        ForEach(filteredRunningApps, id: \.bundleIdentifier) { app in
                            if let bundleID = app.bundleIdentifier,
                               let name = app.localizedName {
                                appRow(bundleID: bundleID, name: name, icon: app.icon)
                            }
                        }
                    } else {
                        ForEach(filteredInstalledApps) { app in
                            appRow(bundleID: app.bundleIdentifier, name: app.displayName, icon: app.icon)
                        }
                    }
                }
            }
            .frame(minHeight: 100, maxHeight: 180)
        } header: {
            Text(appSource == .running
                 ? "Running Apps \u{2014} click to pin / unpin"
                 : "All Apps \u{2014} click to pin / unpin")
        }
    }

    /// Stable, unique picker identities — `localizedName` collides for identical
    /// monitors, so key on the CGDisplay ID and disambiguate duplicate labels.
    private var displayOptions: [(id: UInt32, label: String, name: String)] {
        let screens = NSScreen.screens.sorted(by: { $0.frame.origin.x < $1.frame.origin.x })
        var nameCounts: [String: Int] = [:]
        for screen in screens { nameCounts[screen.localizedName, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return screens.enumerated().map { index, screen in
            let name = screen.localizedName
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
                ?? UInt32(index)
            var label = name
            if nameCounts[name, default: 0] > 1 {
                seen[name, default: 0] += 1
                label = "\(name) (\(seen[name]!))"
            }
            return (id: displayID, label: label, name: name)
        }
    }

    private var filteredRunningApps: [NSRunningApplication] {
        appState.runningApps.filter { app in
            guard !searchText.isEmpty,
                  let name = app.localizedName else { return true }
            return fuzzyMatch(query: searchText, target: name)
        }
    }

    private var filteredInstalledApps: [InstalledAppsService.AppInfo] {
        appState.installedApps.filter { app in
            guard !searchText.isEmpty else { return true }
            return fuzzyMatch(query: searchText, target: app.displayName)
        }
    }

    private func appRow(bundleID: String, name: String, icon: NSImage?) -> some View {
        let pinned = appState.store.isPinned(bundleID)
        return HStack {
            if let icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 20, height: 20)
            }
            Text(name)
            Spacer()
            Image(systemName: pinned ? "pin.fill" : "pin")
                .foregroundStyle(pinned ? Color.accentColor : .secondary)
                .font(.hopCaption)
        }
        .padding(.vertical, HopSpacing.xs)
        .padding(.horizontal, HopSpacing.sm)
        .background(
            RoundedRectangle(cornerRadius: HopRadius.control)
                .fill(pinned ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            appState.store.togglePin(bundleIdentifier: bundleID, displayName: name)
        }
    }
}

// MARK: - Profiles Section

private struct ProfilesSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var newProfileName = ""

    var body: some View {
        Section {
            ForEach(appState.store.profiles) { profile in
                ProfileRow(profile: profile)
            }
        } header: {
            Text("Profiles")
        } footer: {
            Text("Create profiles for different workflows. Expand a profile to edit its sticky note, desktop, and session; use the gear for rename, hotkey, and delete.")
        }

        Section {
            if appState.store.canAddProfile {
                HStack(spacing: HopSpacing.sm) {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(Color.accentColor)
                    TextField("New profile name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addProfile() }
                    Button("Add") { addProfile() }
                        .controlSize(.small)
                        .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                HStack(spacing: HopSpacing.xs) {
                    Image(systemName: "star.fill")
                        .font(.hopCaption)
                        .foregroundStyle(.yellow)
                    Text("Free plan: \(ProFeatureGate.freeProfileLimit) profiles")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                    Link("Unlock unlimited", destination: ProLinks.purchaseURL)
                        .font(.hopCaption)
                }
            }
        }
    }

    private func addProfile() {
        let name = newProfileName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        appState.store.addProfile(name: name)
        newProfileName = ""
    }
}

// MARK: - Profile Row

private struct ProfileRow: View {
    @EnvironmentObject private var appState: AppState
    let profile: Profile

    @State private var isExpanded = false
    @State private var isSettingsOpen = false
    @State private var isEditing = false
    @State private var editingName = ""

    var body: some View {
        if isEditing {
            HStack {
                TextField("Profile name", text: $editingName, onCommit: commitRename)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                Button("Save") { commitRename() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                Button("Cancel") { isEditing = false }
                    .controlSize(.small)
            }
        } else {
            DisclosureGroup(isExpanded: $isExpanded) {
                ProfileDetailView(profile: profile)
            } label: {
                rowLabel
            }
        }
    }

    private var rowLabel: some View {
        HStack(spacing: HopSpacing.xs + 2) {
            Image(systemName: isActive ? "circle.fill" : "circle")
                .foregroundStyle(isActive ? Color.accentColor : .secondary)
                .imageScale(.small)

            Text(profile.name)
                .fontWeight(isActive ? .semibold : .regular)

            Text("\(profile.pinnedApps.count) app\(profile.pinnedApps.count == 1 ? "" : "s")")
                .font(.hopCaption)
                .foregroundStyle(.secondary)

            // Compact status badges
            if appState.store.spaceForProfile(profile.id) != nil {
                Image(systemName: "desktopcomputer")
                    .font(.hopFootnote)
                    .foregroundStyle(.secondary)
                    .help("Assigned to a desktop")
            }
            if profile.hotkey != nil {
                Image(systemName: "keyboard")
                    .font(.hopFootnote)
                    .foregroundStyle(.secondary)
                    .help("Hotkey: \(profile.hotkey!.displayName)")
            }
            if let note = profile.stickyNote, !note.isEmpty {
                Image(systemName: "note.text")
                    .font(.hopFootnote)
                    .foregroundStyle(.secondary)
                    .help("Has a sticky note")
            }

            Spacer()

            if isActive {
                Text("Active")
                    .font(.hopFootnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, HopSpacing.xs + 2)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Button("Activate") {
                    appState.activateProfile(id: profile.id)
                }
                .controlSize(.small)
            }

            Button {
                isSettingsOpen.toggle()
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSettingsOpen ? Color.accentColor : .secondary)
            .popover(isPresented: $isSettingsOpen, arrowEdge: .trailing) {
                ProfileSettingsPopover(profile: profile, isEditing: $isEditing, editingName: $editingName)
                    .environmentObject(appState)
            }
        }
    }

    private var isActive: Bool { profile.id == appState.store.activeProfileId }

    private func commitRename() {
        let name = editingName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            appState.store.renameProfile(id: profile.id, to: name)
        }
        isEditing = false
    }
}

// MARK: - Profile Detail (inline, replaces popover junk drawer)

private struct ProfileDetailView: View {
    @EnvironmentObject private var appState: AppState
    let profile: Profile

    @State private var noteText: String = ""
    @State private var noteSaveTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: HopSpacing.md) {
            // Sticky note — front and center for discoverability.
            VStack(alignment: .leading, spacing: HopSpacing.xs) {
                Label("Sticky Note", systemImage: "note.text")
                    .font(.hopSubheading)
                    .foregroundStyle(.secondary)
                TextEditor(text: $noteText)
                    .font(.body)
                    .frame(height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: HopRadius.control)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                Text("Shown when switching to this profile")
                    .font(.hopFootnote)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // Desktop assignment
            LabeledContent {
                if appState.store.spaceForProfile(profile.id) != nil {
                    Button("Reassign") {
                        appState.store.assignProfileToCurrentSpace(profileId: profile.id)
                    }
                    .controlSize(.small)
                    Button("Remove") {
                        appState.store.unassignProfileFromSpace(profileId: profile.id)
                    }
                    .controlSize(.small)
                    .foregroundStyle(.red.opacity(0.7))
                } else {
                    Button("Assign current") {
                        appState.store.assignProfileToCurrentSpace(profileId: profile.id)
                    }
                    .controlSize(.small)
                }
            } label: {
                Label(
                    appState.store.spaceForProfile(profile.id) != nil ? "Desktop assigned" : "No desktop",
                    systemImage: "desktopcomputer"
                )
                .foregroundStyle(.secondary)
            }

            // Windows-to-desktop move (only meaningful with a desktop assigned)
            VStack(alignment: .leading, spacing: HopSpacing.xs) {
                Toggle("Move windows to this desktop", isOn: Binding(
                    get: { appState.store.movesWindowsToAssignedSpace(profile.id) },
                    set: { appState.store.setMoveWindowsToAssignedSpace(profileId: profile.id, enabled: $0) }
                ))
                .disabled(appState.store.spaceForProfile(profile.id) == nil)
                Text(appState.store.spaceForProfile(profile.id) == nil
                     ? "Assign a desktop first. When on, switching to this profile also moves its apps' windows onto that desktop."
                     : "When switching to this profile, its apps' windows are moved onto the assigned desktop instead of only hiding other apps.")
                    .font(.hopFootnote)
                    .foregroundStyle(.tertiary)
                if appState.spaceMoveUnsupported && appState.store.movesWindowsToAssignedSpace(profile.id) {
                    HStack(spacing: HopSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle")
                        Text("Not supported on this macOS version — HopTab falls back to hiding other apps.")
                    }
                    .font(.hopFootnote)
                    .foregroundStyle(.orange)
                }
            }

            // Session save / restore
            LabeledContent {
                HStack(spacing: HopSpacing.sm) {
                    if appState.canRestoreSession(profileId: profile.id) {
                        Button {
                            appState.restoreSession(profileId: profile.id)
                        } label: {
                            Label("Restore", systemImage: "arrow.counterclockwise")
                        }
                        .controlSize(.small)
                    }

                    if SessionSnapshotService.hasRunningApps(profile) {
                        Button {
                            appState.saveAndCloseSession(profileId: profile.id)
                        } label: {
                            Label("Save & Close", systemImage: "tray.and.arrow.down")
                        }
                        .controlSize(.small)
                    }

                    if !appState.canRestoreSession(profileId: profile.id) &&
                        !SessionSnapshotService.hasRunningApps(profile) {
                        Text("No saved session")
                            .font(.hopCaption)
                            .foregroundStyle(.tertiary)
                    }
                }
            } label: {
                Label("Session", systemImage: "tray.and.arrow.down")
                    .foregroundStyle(.secondary)
            }

            // Launch order — per-app options for Restore Session
            if !profile.pinnedApps.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: HopSpacing.xs) {
                        ForEach(profile.pinnedApps, id: \.bundleIdentifier) { app in
                            LaunchOptionsRow(profileId: profile.id, app: app)
                        }
                        Text("Lower priority launches first. Delay staggers an app within its group. Open lets an app start with a file, folder, or URL.")
                            .font(.hopFootnote)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.top, HopSpacing.xs)
                } label: {
                    Label("Launch order", systemImage: "list.number")
                        .foregroundStyle(.secondary)
                }
            }

            // Layout summary
            LabeledContent {
                Text("Configure in Layouts section")
                    .font(.hopFootnote)
                    .foregroundStyle(.tertiary)
            } label: {
                if let binding = profile.layoutBinding,
                   let template = appState.store.allTemplates.first(where: { $0.id == binding.templateId }) {
                    Label {
                        Text(template.name) +
                        Text(" (\(binding.zoneAssignments.count) zone\(binding.zoneAssignments.count == 1 ? "" : "s"))")
                            .font(.hopCaption)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "rectangle.3.group")
                    }
                } else {
                    Label("No layout", systemImage: "rectangle.3.group")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, HopSpacing.xs)
        .onAppear { noteText = profile.stickyNote ?? "" }
        .onChange(of: noteText) {
            scheduleNoteSave(noteText)
        }
        .onDisappear {
            // Flush any pending debounce so the last edit is never lost.
            noteSaveTask?.cancel()
            if noteText != (profile.stickyNote ?? "") {
                appState.store.setStickyNote(profileId: profile.id, note: noteText)
            }
        }
    }

    /// Debounced autosave (~0.5 s) so we don't write on every keystroke.
    private func scheduleNoteSave(_ text: String) {
        noteSaveTask?.cancel()
        let profileId = profile.id
        noteSaveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            appState.store.setStickyNote(profileId: profileId, note: text)
        }
    }
}

// MARK: - Launch Options Row (per-app restore orchestration)

private struct LaunchOptionsRow: View {
    @EnvironmentObject private var appState: AppState
    let profileId: UUID
    let app: PinnedApp

    @State private var priorityText: String = ""
    @State private var delayText: String = ""
    @State private var urlsText: String = ""
    @State private var skip: Bool = false

    var body: some View {
        HStack(spacing: HopSpacing.sm) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(app.displayName)
                .font(.hopCaption)
                .frame(width: 110, alignment: .leading)
                .lineLimit(1)

            TextField("Priority", text: $priorityText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .help("Lower launches first; empty launches last")
                .onSubmit(save)

            TextField("Delay s", text: $delayText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 60)
                .help("Seconds to wait within its group")
                .onSubmit(save)

            TextField("Open URL / path", text: $urlsText)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 120, maxWidth: .infinity)
                .help("Comma-separated URLs or file paths to open in this app")
                .onSubmit(save)

            Toggle("Skip", isOn: $skip)
                .toggleStyle(.checkbox)
                .help("Keep pinned but don't auto-launch on restore")
                .onChange(of: skip) { _ in save() }
        }
        .controlSize(.small)
        .onAppear(perform: load)
    }

    private func load() {
        let options = appState.store.launchOptions(profileId: profileId, bundleId: app.bundleIdentifier)
        priorityText = options?.launchPriority.map(String.init) ?? ""
        delayText = options?.launchDelay.map { String(Int($0)) } ?? ""
        urlsText = options?.openURLs?.joined(separator: ", ") ?? ""
        skip = options?.skipOnRestore ?? false
    }

    private func save() {
        let urls = urlsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let options = LaunchOptions(
            launchPriority: Int(priorityText.trimmingCharacters(in: .whitespaces)),
            launchDelay: TimeInterval(delayText.trimmingCharacters(in: .whitespaces)),
            openURLs: urls.isEmpty ? nil : urls,
            skipOnRestore: skip ? true : nil
        )
        appState.store.setLaunchOptions(
            profileId: profileId,
            bundleId: app.bundleIdentifier,
            options: options.isEmpty ? nil : options
        )
    }
}

// MARK: - Profile Settings Popover (rename / hotkey / delete)

private struct ProfileSettingsPopover: View {
    @EnvironmentObject private var appState: AppState
    let profile: Profile
    @Binding var isEditing: Bool
    @Binding var editingName: String

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: HopSpacing.md) {
            // Rename
            Button {
                editingName = profile.name
                isEditing = true
                dismiss()
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)

            Divider()

            // Hotkey
            ProfileHotkeyRow(profile: profile)

            if appState.store.profiles.count > 1 {
                Divider()

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("Delete Profile\u{2026}", systemImage: "trash")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
                .alert("Delete Profile", isPresented: $showDeleteConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Delete", role: .destructive) {
                        appState.store.deleteProfile(id: profile.id)
                        dismiss()
                    }
                } message: {
                    Text("Delete \"\(profile.name)\"? This will remove all its pinned apps, layout assignments, and saved sessions.")
                }
            }
        }
        .padding(HopSpacing.md)
        .frame(width: 280)
    }
}

// MARK: - Profile Hotkey Row

private struct ProfileHotkeyRow: View {
    @EnvironmentObject private var appState: AppState
    let profile: Profile

    @State private var shortcut: CustomShortcut?

    var body: some View {
        HStack(spacing: HopSpacing.xs) {
            Image(systemName: "keyboard")
                .font(.hopCaption)
                .foregroundStyle(.secondary)

            Text("Hotkey:")
                .font(.hopCaption)
                .foregroundStyle(.secondary)

            ShortcutRecorderView(shortcut: $shortcut)
                .onChange(of: shortcut) {
                    appState.store.setProfileHotkey(id: profile.id, hotkey: shortcut)
                }

            if shortcut != nil {
                Button("Clear") {
                    shortcut = nil
                    appState.store.setProfileHotkey(id: profile.id, hotkey: nil)
                }
                .controlSize(.small)
            }

            if let conflict = hotkeyConflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.hopCaption)
                    .help(conflict)
            }
        }
        .onAppear {
            shortcut = profile.hotkey
        }
    }

    private var hotkeyConflict: String? {
        guard let hk = shortcut else { return nil }

        // Check against app switcher shortcut
        let appSel = appState.appShortcutSelection
        if appSel.modifierFlags == hk.modifierFlags && appSel.keyCode == hk.keyCode {
            return "Conflicts with app switcher shortcut"
        }

        // Check against other profiles
        for p in appState.store.profiles where p.id != profile.id {
            if let other = p.hotkey,
               other.modifierFlagsRawValue == hk.modifierFlagsRawValue && other.keyCode == hk.keyCode {
                return "Conflicts with \(p.name) profile hotkey"
            }
        }

        return nil
    }
}

// MARK: - Layouts Section

private struct LayoutsSection: View {
    @EnvironmentObject private var appState: AppState

    private var profile: Profile? {
        appState.store.activeProfile
    }

    var body: some View {
        Section {
            ActiveProfilePicker()
        }

        if let profile {
            Section {
                LayoutPickerContent(profile: profile)
            }

            // DISABLED: BSP auto-tiling config (Pro) is commented out for this
            // release — see ProBridge.swift / HopTabProModule.swift.
            // if let provider = ProServiceRegistry.shared.provider,
            //    let bspView = provider.bspTilingSectionView() {
            //     Section {
            //         bspView
            //     }
            // }
        } else {
            Section {
                VStack(spacing: HopSpacing.sm) {
                    Image(systemName: "rectangle.3.group")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("Create a profile first to configure layouts")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HopSpacing.lg)
            }
        }
    }
}

// MARK: - Shortcuts Section

private struct ShortcutsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switcherShortcutSection
        profileShortcutSection
        behaviorSection
        howItWorksSection
    }

    private var switcherShortcutSection: some View {
        Section {
            // Preset grid — 2 columns
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: HopSpacing.xs + 2) {
                ForEach(ShortcutPreset.allCases) { preset in
                    presetCard(preset)
                }
                customCard
            }

            if appState.shortcutsConflict {
                conflictBanner
            }

            // Recovery UI — surface Retry / Open Settings when the hotkey is degraded.
            if appState.hotkeyStatus != .running {
                hotkeyStatusRow
            }
        } header: {
            HStack {
                Text("App Switcher")
                Spacer()
                hotkeyStatusBadge
            }
        } footer: {
            Text("Hold the modifier, tap the trigger key to cycle, release to switch.")
        }
    }

    private func presetCard(_ preset: ShortcutPreset) -> some View {
        let isSelected = appState.selectedPreset == preset
        return Button { appState.selectPreset(preset) } label: {
            HStack {
                Text(preset.displayName)
                    .font(isSelected ? .hopSubheading.weight(.semibold) : .hopSubheading)
                Spacer()
            }
            .padding(.horizontal, HopSpacing.sm + 2)
            .padding(.vertical, HopSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HopRadius.control)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: HopRadius.control)
                            .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var customCard: some View {
        let isSelected = appState.isCustomAppShortcut
        return Button { appState.selectCustomMode() } label: {
            HStack(spacing: HopSpacing.xs + 2) {
                Text("Custom")
                    .font(isSelected ? .hopSubheading.weight(.semibold) : .hopSubheading)
                if isSelected {
                    ShortcutRecorderView(shortcut: $appState.customAppShortcut)
                        .frame(maxWidth: 80)
                }
                Spacer()
            }
            .padding(.horizontal, HopSpacing.sm + 2)
            .padding(.vertical, HopSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HopRadius.control)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: HopRadius.control)
                            .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var profileShortcutSection: some View {
        Section("Profile Switcher") {
            LabeledContent {
                HStack(spacing: HopSpacing.md) {
                    if appState.isCustomProfileShortcut {
                        ShortcutRecorderView(shortcut: $appState.customProfileShortcut)
                    } else {
                        Text("\(appState.profileShortcutModifierName) + \(appState.profileShortcutKeyName)")
                            .font(.hopSubheading.weight(.medium))
                            .padding(.horizontal, HopSpacing.sm + 2)
                            .padding(.vertical, HopSpacing.xs + 2)
                            .background(RoundedRectangle(cornerRadius: HopRadius.control).fill(Color.primary.opacity(0.06)))
                    }
                    Toggle("Custom", isOn: $appState.isCustomProfileShortcut)
                        .font(.hopCaption)
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
            } label: {
                Text("Shortcut")
            }

            if appState.shortcutsConflict {
                conflictBanner
            }
        }
    }

    private var behaviorSection: some View {
        Section("Behavior") {
            Toggle("Move recently switched app to front", isOn: $appState.recentAppFirst)
        }
    }

    private var howItWorksSection: some View {
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: HopSpacing.xs) {
                    let sel = appState.appShortcutSelection
                    shortcutHint("\(sel.modifierName)+\(sel.keyName)", "Show switcher & cycle forward")
                    shortcutHint("Shift+\(sel.modifierName)+\(sel.keyName)", "Cycle backward")
                    shortcutHint("Release \(sel.modifierName)", "Activate selected")
                    shortcutHint("Esc", "Cancel")
                    shortcutHint("\u{2318}Q / \u{2318}H / \u{2318}M", "Quit / Hide / Minimize")
                    Divider().padding(.vertical, 2)
                    shortcutHint("\(appState.profileShortcutModifierName)+\(appState.profileShortcutKeyName)", "Show profile switcher")
                }
                .padding(.top, HopSpacing.xs + 2)
            } label: {
                Text("Quick Reference")
                    .font(.hopSubheading)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func shortcutHint(_ keys: String, _ description: String) -> some View {
        HStack(spacing: HopSpacing.sm) {
            Text(keys)
                .font(.hopCaption.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .frame(width: 160, alignment: .leading)
            Text(description)
                .font(.hopCaption)
                .foregroundStyle(.secondary)
        }
    }

    private var hotkeyStatusBadge: some View {
        HStack(spacing: HopSpacing.xs) {
            switch appState.hotkeyStatus {
            case .running:
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Active").font(.hopFootnote).foregroundStyle(.green)
            case .failed:
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text("No access").font(.hopFootnote).foregroundStyle(.orange)
            case .stopped:
                Circle().fill(Color.gray).frame(width: 6, height: 6)
                Text("Stopped").font(.hopFootnote).foregroundStyle(.secondary)
            }
        }
    }

    private var conflictBanner: some View {
        HStack(spacing: HopSpacing.xs + 2) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("App and profile shortcuts conflict \u{2014} app switcher takes priority.")
        }
        .font(.hopCaption)
        .foregroundStyle(.orange)
        .padding(HopSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: HopRadius.control))
    }

    private var hotkeyStatusRow: some View {
        VStack(alignment: .leading, spacing: HopSpacing.sm) {
            HStack(spacing: HopSpacing.xs + 2) {
                Text("Status:")
                    .foregroundStyle(.secondary)
                switch appState.hotkeyStatus {
                case .running:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Active")
                        .foregroundStyle(.green)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Failed \u{2014} grant Accessibility in System Settings")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Retry") {
                        appState.retryHotkey()
                    }
                case .stopped:
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                    Text("Not started")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.hopSubheading)

            if !appState.permissions.isTrusted {
                Button("Open Accessibility Settings") {
                    appState.permissions.requestAccessibility()
                }
            }
        }
    }
}

// MARK: - Snapping Section

private struct SnappingSection: View {
    @State private var gapSize: Double = UserDefaults.standard.double(forKey: "windowGap")
    @State private var snapConfig: SnapShortcutConfig = SnapShortcutConfig.current

    /// Curated grouping, with a dynamic catch-all so new SnapDirection cases
    /// added to the enum appear automatically without a UI change.
    private var shortcutGroups: [(title: String, directions: [SnapDirection])] {
        var groups: [(title: String, directions: [SnapDirection])] = [
            ("Halves", [.left, .right, .topHalf, .bottomHalf]),
            ("Quarters", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
            ("Thirds", [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds]),
            ("Other", [.full, .center]),
            ("Resize", [.growSplit, .shrinkSplit]),
            ("Cycle", [.cycleNext, .cyclePrevious]),
            ("Monitors", [.nextMonitor, .previousMonitor]),
            ("Actions", [.undo]),
        ]
        let covered = Set(groups.flatMap(\.directions))
        let remaining = SnapDirection.allCases.filter { !covered.contains($0) && $0 != .redo }
        if !remaining.isEmpty {
            groups.append(("More", remaining))
        }
        return groups
    }

    @EnvironmentObject private var appState: AppState
    @State private var restoreOnUnsnap: Bool =
        UserDefaults.standard.object(forKey: DragSnapService.restoreOnUnsnapDefaultsKey) as? Bool ?? true

    var body: some View {
        Section {
            Toggle("Drag to Snap", isOn: $appState.dragSnapEnabled)
            Toggle("Restore size when dragging away", isOn: $restoreOnUnsnap)
                .onChange(of: restoreOnUnsnap) { newValue in
                    UserDefaults.standard.set(newValue, forKey: DragSnapService.restoreOnUnsnapDefaultsKey)
                }
        } header: {
            Text("Snapping")
        } footer: {
            Text(appState.dragSnapEnabled
                 ? "Drag any window to a screen edge or corner to snap it into position. May use slightly more CPU while enabled."
                 : "Drag any window to a screen edge or corner to snap it into position.")
        }

        Section {
            LabeledContent("Window Gap") {
                HStack(spacing: HopSpacing.md) {
                    // Preview
                    HStack(spacing: gapSize > 0 ? gapSize / 2 : 0) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.4))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.accentColor.opacity(0.25))
                    }
                    .padding(gapSize > 0 ? gapSize / 3 : 0)
                    .frame(width: 80, height: 40)
                    .background(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))
                    .animation(.easeInOut(duration: 0.15), value: gapSize)

                    Slider(value: $gapSize, in: 0...20, step: 1)
                        .frame(minWidth: 120)
                        .onChange(of: gapSize) {
                            UserDefaults.standard.set(gapSize, forKey: "windowGap")
                        }

                    Text("\(Int(gapSize)) pt")
                        .font(.hopCaption.monospaced())
                        .foregroundStyle(.secondary)
                        .frame(width: 35)
                }
            }
        }

        Section {
            if !allConflicts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allConflicts, id: \.self) { message in
                        HStack(spacing: HopSpacing.xs + 2) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(message)
                        }
                        .font(.hopCaption)
                        .foregroundStyle(.orange)
                    }
                }
                .padding(HopSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: HopRadius.control))
            }

            ForEach(shortcutGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.hopFootnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .padding(.top, HopSpacing.xs + 2)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: HopSpacing.xs) {
                        ForEach(group.directions, id: \.self) { direction in
                            snapShortcutRow(direction: direction)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Snap Shortcuts")
                Spacer()
                Button("Reset") {
                    snapConfig = .defaults
                    saveConfig()
                }
                .controlSize(.mini)
                .foregroundStyle(.secondary)
            }
        } footer: {
            Text("Global hotkeys to snap windows. Press the same key twice to cycle sizes.")
        }
    }

    private func snapShortcutRow(direction: SnapDirection) -> some View {
        HStack(spacing: HopSpacing.xs) {
            Text(direction.displayName)
                .font(.hopCaption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            if let conflict = conflictName(for: direction) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.hopFootnote)
                    .foregroundStyle(.orange)
                    .help("Conflicts with \(conflict)")
            }

            ShortcutRecorderView(shortcut: binding(for: direction))
                .frame(width: 80)

            if snapConfig.bindings[direction] != nil {
                Button {
                    snapConfig.bindings.removeValue(forKey: direction)
                    saveConfig()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.hopFootnote)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 14)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func binding(for direction: SnapDirection) -> Binding<CustomShortcut?> {
        Binding(
            get: { snapConfig.bindings[direction] },
            set: { newValue in
                if let shortcut = newValue {
                    snapConfig.bindings[direction] = shortcut
                } else {
                    snapConfig.bindings.removeValue(forKey: direction)
                }
                saveConfig()
            }
        )
    }

    private func saveConfig() {
        SnapShortcutConfig.current = snapConfig
        NotificationCenter.default.post(name: .snapShortcutsChanged, object: nil)
    }

    // MARK: Conflict detection (warn, but allow saving)

    /// Name of whatever else already uses this direction's shortcut, or nil.
    private func conflictName(for direction: SnapDirection) -> String? {
        guard let hk = snapConfig.bindings[direction] else { return nil }

        // App switcher shortcut
        let appSel = appState.appShortcutSelection
        if appSel.modifierFlags == hk.modifierFlags && appSel.keyCode == hk.keyCode {
            return "the app switcher shortcut"
        }

        // Profile hotkeys
        for p in appState.store.profiles {
            if let other = p.hotkey,
               other.modifierFlagsRawValue == hk.modifierFlagsRawValue && other.keyCode == hk.keyCode {
                return "the \(p.name) profile hotkey"
            }
        }

        // Other snap bindings
        for (otherDirection, other) in snapConfig.bindings where otherDirection != direction {
            if other.modifierFlagsRawValue == hk.modifierFlagsRawValue && other.keyCode == hk.keyCode {
                return "the \(otherDirection.displayName) snap shortcut"
            }
        }

        return nil
    }

    private var allConflicts: [String] {
        shortcutGroups.flatMap(\.directions).compactMap { direction in
            conflictName(for: direction).map {
                "\(direction.displayName) conflicts with \($0)"
            }
        }
    }
}

// MARK: - Pro Upsell Row (shared)

private struct ProUpsellRow: View {
    var body: some View {
        HStack(spacing: HopSpacing.xs + 2) {
            Image(systemName: "star.fill")
                .font(.hopCaption)
                .foregroundStyle(.yellow)
            Text("Available with HopTab Pro")
                .foregroundStyle(.secondary)
            Link("Learn more", destination: ProLinks.purchaseURL)
        }
        .font(.hopSubheading)
    }
}

// MARK: - Window Rules Section

private struct WindowRulesSection: View {
    var body: some View {
        Section {
            if let provider = ProServiceRegistry.shared.provider,
               let view = provider.windowsSectionView() {
                view
            } else {
                ProUpsellRow()
            }
        } header: {
            Text("Window Rules")
        } footer: {
            Text("Set a rule like \"Chrome \u{2192} Left Half on launch\" and it will always open there. Great for keeping your workspace consistent without manually snapping every time.")
        }
    }
}

// MARK: - Pro Section

private struct ProSection: View {
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: HopSpacing.sm) {
                HStack(spacing: HopSpacing.sm + 2) {
                    Image(systemName: "star.circle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HopTab Pro")
                            .font(.title3.weight(.bold))
                        Text("Automate your workspace \u{2014} let HopTab work for you.")
                            .font(.hopSubheading)
                            .foregroundStyle(.secondary)
                    }
                }

                if ProServiceRegistry.shared.isLicensed {
                    HStack(spacing: HopSpacing.xs + 2) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Pro Active")
                            .font(.hopSubheading.weight(.medium))
                            .foregroundStyle(.green)
                    }
                    .padding(.top, HopSpacing.xs)
                } else {
                    Link(destination: ProLinks.purchaseURL) {
                        Text("Unlock Pro \u{2014} $5 one-time")
                            .font(.hopSubheading.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, HopSpacing.sm + 2)
                            .background(RoundedRectangle(cornerRadius: HopRadius.card - 2).fill(Color.accentColor))
                    }
                    .padding(.top, HopSpacing.xs)

                    Link(destination: URL(string: "https://github.com/sponsors/royalbhati")!) {
                        Text("or sponsor on GitHub")
                            .font(.hopCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        Section("Pro Features") {
            proFeature(
                icon: "clock.fill", color: .blue,
                title: "Time Tracking",
                description: "See exactly how long you spend in each profile. Zero effort \u{2014} works automatically from profile switches."
            )

            proFeature(
                icon: "calendar", color: .red,
                title: "Calendar Auto-Switch",
                description: "\"Daily Standup\" starts \u{2192} switches to Meeting profile. Detects Zoom, Teams, Meet links. Fullscreen reminder with Join button."
            )

            proFeature(
                icon: "clock.badge", color: .orange,
                title: "Time Schedule",
                description: "\"At 7 PM switch to Entertainment\" \u{2014} set it once, works every day. Filter by weekday."
            )

            proFeature(
                icon: "moon.fill", color: .purple,
                title: "Focus Mode Integration",
                description: "Enable \"Work\" Focus \u{2192} auto-switches to your Work profile. Assign multiple profiles per Focus mode."
            )

            proFeature(
                icon: "display", color: .cyan,
                title: "Display Auto-Profiles",
                description: "Plug in your external monitor \u{2192} auto-switches to \"Docked\" profile. Unplug \u{2192} switches to \"Laptop\"."
            )

            proFeature(
                icon: "rectangle.badge.plus", color: .green,
                title: "Window Rules",
                description: "\"VS Code always left 60%\" \u{2014} set once, auto-snaps on every launch or focus. Free tier gets 2 rules."
            )

            proFeature(
                icon: "rectangle.3.group.fill", color: .yellow,
                title: "Custom Layouts",
                description: "Create layouts with exact width and height percentages. Build any arrangement you want."
            )

            proFeature(
                icon: "person.2.fill", color: .indigo,
                title: "Unlimited Profiles",
                description: "Free tier allows 3 profiles. Pro unlocks unlimited."
            )
        }

        // License entry
        if let provider = ProServiceRegistry.shared.provider {
            Section {
                provider.licenseSectionView()
            }
        }

        // Student/affordability note
        if !ProServiceRegistry.shared.isLicensed {
            Section {
                VStack(alignment: .leading, spacing: HopSpacing.xs) {
                    Text("Can't afford it?")
                        .font(.hopSubheading.weight(.medium))
                    Text("If you're a student or really think these features can make your life better but can't afford $5 \u{2014} send me an email and I'll give you Pro for free. No questions asked.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                    Link("rawyelll@gmail.com", destination: URL(string: "mailto:rawyelll@gmail.com?subject=HopTab%20Pro%20Request")!)
                        .font(.hopCaption)
                }
            }
        }
    }

    private func proFeature(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: HopSpacing.md) {
            Image(systemName: icon)
                .font(.hopSubheading)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(color.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.hopSubheading.weight(.semibold))
                Text(description)
                    .font(.hopCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Window Undo Section

private struct WindowUndoSection: View {
    var body: some View {
        // The Pro view is a self-titled card; only headline the locked state.
        if let provider = ProServiceRegistry.shared.provider,
           let view = provider.windowUndoSectionView() {
            Section {
                view
            }
        } else {
            Section {
                ProUpsellRow()
            } header: {
                Text("Window Undo")
            } footer: {
                Text("Undo any window move or resize. Full history \u{2014} step back through your last 50 window operations.")
            }
        }
    }
}

// MARK: - Look & Feel Section (Pro)
// DISABLED for this release (Focus Border / Focus Dimming / rice presets /
// profile visuals) — uncomment together with ProBridge.swift and
// HopTabProModule.swift to restore.

// private struct LookAndFeelSection: View {
//     @EnvironmentObject private var appState: AppState
//
//     var body: some View {
//         Section {
//             if let provider = ProServiceRegistry.shared.provider, provider.isLicensed {
//                 if let view = provider.focusBorderSectionView() { view }
//                 if let view = provider.focusDimmingSectionView() { view }
//                 if let view = provider.ricePresetsSectionView() { view }
//                 if let view = provider.profileVisualsSectionView(
//                     profiles: appState.store.profiles.map { ProProfileInfo(id: $0.id, name: $0.name) }
//                 ) { view }
//             } else {
//                 ProUpsellRow()
//             }
//         } header: {
//             Text("Look & Feel")
//         } footer: {
//             Text("Focus borders, dimming of unfocused windows, and rice presets \u{2014} make your workspace look the part.")
//         }
//     }
// }

// MARK: - Advanced Space Control Section

private struct AdvancedSpaceControlSection: View {
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
                    case .enabled, .unknown, nil:
                        Text("HopTab's tiling, snapping, and profiles work fully with System Integrity Protection on. A small set of extras — instant desktop switching without animation, window opacity effects — would require reducing SIP the way yabai users do. HopTab does not recommend this for most users: it weakens macOS security, must be redone from Recovery mode, and can break on macOS updates.")
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
        } label: {
            Label("System Integrity Protection", systemImage: "lock.shield")
                .foregroundStyle(.secondary)
        }
    }

    private var sipStatusLabel: String {
        switch sipStatus {
        case .enabled: return "Enabled"
        case .partiallyDisabled: return "Custom configuration — advanced space control available"
        case .disabled: return "Disabled — advanced space control available"
        case .unknown: return "Unknown"
        case nil: return "Checking\u{2026}"
        }
    }
}

// MARK: - Screen Breaks Section

private struct ScreenBreaksSection: View {
    var body: some View {
        // The Pro view is a self-titled card; only headline the locked state.
        if let provider = ProServiceRegistry.shared.provider,
           let view = provider.screenBreaksSectionView() {
            view
        } else {
            VStack(alignment: .leading, spacing: HopSpacing.sm) {
                Text("Screen Breaks")
                    .font(.hopHeading)
                Text("Workspace-aware break reminders. Shows a break screen with countdown, then restores everything when you return.")
                    .font(.hopCaption)
                    .foregroundStyle(.secondary)
                ProUpsellRow()
            }
        }
    }
}

// MARK: - Displays Section (Pro only)

private struct DisplaysSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // The Pro view is a self-titled card — no duplicate heading.
        if let provider = ProServiceRegistry.shared.provider {
            provider.displaysSectionView(profiles: appState.store.profiles.map { ProProfileInfo(id: $0.id, name: $0.name) })
        }
    }
}

// MARK: - About Section

private struct AboutSection: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var updateService = UpdateService.shared

    var body: some View {
        Section {
            VStack(spacing: HopSpacing.md) {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)

                Text("HopTab")
                    .font(.title)
                    .fontWeight(.bold)

                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")")
                    .foregroundStyle(.secondary)

                Text("A supercharged macOS app switcher.\nPin your favorite apps and switch between them instantly.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
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

        // Pro license section
        if let provider = ProServiceRegistry.shared.provider {
            Section {
                provider.licenseSectionView()
            }
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let snapShortcutsChanged = Notification.Name("snapShortcutsChanged")
}
