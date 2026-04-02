import SwiftUI

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
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: 720, height: 580)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "HopTab"
        w.contentView = hostingView
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }
}

// MARK: - Sidebar Navigation

private enum SettingsSection: String, CaseIterable, Identifiable {
    case apps = "Apps"
    case profiles = "Profiles"
    case layouts = "Layouts"
    case shortcuts = "Shortcuts"
    case snapping = "Snapping"
    case windowRules = "Window Rules"
    case displays = "Displays"
    case pro = "Pro"
    case about = "About"

    var id: String { rawValue }
}

// MARK: - Settings Root View

private struct SettingsRootView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selection: SettingsSection = .apps

    private var sections: [SettingsSection] {
        var result: [SettingsSection] = [.apps, .profiles, .layouts, .shortcuts, .snapping, .windowRules]
        if ProServiceRegistry.shared.isProAvailable {
            result.append(.displays)
        }
        result.append(.pro)
        result.append(.about)
        return result
    }

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sections) { section in
                    sidebarItem(section)
                }
                Spacer()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
            .frame(width: 180)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Content
            ScrollView {
                contentView
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(NSColor.controlBackgroundColor))
        }
    }

    private func sidebarItem(_ section: SettingsSection) -> some View {
        Button {
            selection = section
        } label: {
            Text(section.rawValue)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(selection == section ? Color.primary.opacity(0.06) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var contentView: some View {
        switch selection {
        case .apps:
            PinnedAppsSection()
        case .profiles:
            ProfilesSection()
        case .layouts:
            LayoutsSection()
        case .shortcuts:
            ShortcutsSection()
        case .snapping:
            SnappingSection()
        case .windowRules:
            WindowRulesSection()
        case .displays:
            DisplaysSection()
        case .pro:
            ProSection()
        case .about:
            AboutSection()
        }
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
        VStack(alignment: .leading, spacing: 20) {
            // Active profile indicator
            if let profile = appState.store.activeProfile {
                HStack {
                    Text("Profile:")
                        .foregroundStyle(.secondary)
                    Text(profile.name)
                        .fontWeight(.medium)
                    Spacer()
                    profilePicker
                }
                .font(.system(size: 12))
            }

            // Pinned apps section
            VStack(alignment: .leading, spacing: 10) {
                Text("Pinned Apps")
                    .font(.system(size: 13, weight: .semibold))
                Text("Pin the apps you use most. Use Option+Tab to cycle through only these apps instead of everything running.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if appState.store.apps.isEmpty {
                    VStack(spacing: 6) {
                        Image(systemName: "pin")
                            .font(.system(size: 20))
                            .foregroundStyle(.tertiary)
                        Text("No apps pinned yet")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text("Click the pin icon on any app below to add it")
                            .font(.system(size: 11))
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
                    .frame(minHeight: 80, maxHeight: 150)
                }
            }

            // Source picker + search
            VStack(alignment: .leading, spacing: 10) {
                Text(appSource == .running
                     ? "Running Apps \u{2014} click to pin / unpin"
                     : "All Apps \u{2014} click to pin / unpin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(spacing: 8) {
                    Picker("", selection: $appSource) {
                        ForEach(AppSource.allCases, id: \.self) { source in
                            Text(source.rawValue).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)

                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.secondary)
                        TextField("Filter apps\u{2026}", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))

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
                    .frame(minHeight: 80, maxHeight: 150)
                }
            }
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
                .font(.system(size: 12))
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(pinned ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            appState.store.togglePin(bundleIdentifier: bundleID, displayName: name)
        }
    }

    private var profilePicker: some View {
        Menu {
            ForEach(appState.store.profiles) { profile in
                Button {
                    appState.activateProfile(id: profile.id)
                } label: {
                    HStack {
                        Text(profile.name)
                        if profile.id == appState.store.activeProfileId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Switch")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Profiles Section

private struct ProfilesSection: View {
    @EnvironmentObject private var appState: AppState
    @State private var newProfileName = ""
    @State private var settingsProfileId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Profiles list
            VStack(alignment: .leading, spacing: 10) {
                Text("Profiles")
                    .font(.system(size: 13, weight: .semibold))

                Text("Create profiles for different workflows. Click the gear icon to configure desktop assignment and hotkey.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                List {
                    ForEach(appState.store.profiles) { profile in
                        ProfileRow(
                            profile: profile,
                            isSettingsOpen: Binding(
                                get: { settingsProfileId == profile.id },
                                set: { settingsProfileId = $0 ? profile.id : nil }
                            )
                        )
                        .padding(.vertical, 2)
                    }
                }
                .frame(height: min(CGFloat(appState.store.profiles.count) * 48 + 8, 350))
            }

            // New profile — always visible, compact
            if appState.store.canAddProfile {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.accentColor)
                    TextField("New profile name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .onSubmit { addProfile() }
                    Button("Add") { addProfile() }
                        .controlSize(.small)
                        .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                    Text("Free plan: \(ProFeatureGate.freeProfileLimit) profiles")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Link("Unlock unlimited", destination: URL(string: "https://buy.polar.sh/polar_cl_iKgZQ7w4AWRhnNzsnQBl80syKnFJGHJj1Pv6d2a9tD7")!)
                        .font(.system(size: 11))
                }
            }

            // Pro automation features
            if let provider = ProServiceRegistry.shared.provider {
                provider.profileSectionViews(profiles: appState.store.profiles.map { ProProfileInfo(id: $0.id, name: $0.name) })
            }

            Spacer()
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
    @Binding var isSettingsOpen: Bool

    @State private var isEditing = false
    @State private var editingName = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                HStack(spacing: 6) {
                    Image(systemName: isActive ? "circle.fill" : "circle")
                        .foregroundStyle(isActive ? Color.accentColor : .secondary)
                        .font(.system(size: 8))

                    Text(profile.name)
                        .fontWeight(isActive ? .semibold : .regular)

                    Text("\(profile.pinnedApps.count) app\(profile.pinnedApps.count == 1 ? "" : "s")")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    // Compact status badges
                    if appState.store.spaceForProfile(profile.id) != nil {
                        Image(systemName: "desktopcomputer")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help("Assigned to a desktop")
                    }
                    if profile.hotkey != nil {
                        Image(systemName: "keyboard")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                            .help("Hotkey: \(profile.hotkey!.displayName)")
                    }

                    Spacer()

                    if isActive {
                        Text("Active")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
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

                    if appState.store.profiles.count > 1 {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red.opacity(0.7))
                        .alert("Delete Profile", isPresented: $showDeleteConfirmation) {
                            Button("Cancel", role: .cancel) {}
                            Button("Delete", role: .destructive) {
                                appState.store.deleteProfile(id: profile.id)
                            }
                        } message: {
                            Text("Delete \"\(profile.name)\"? This will remove all its pinned apps, layout assignments, and saved sessions.")
                        }
                    }
                }
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

// MARK: - Profile Settings Popover

private struct ProfileSettingsPopover: View {
    @EnvironmentObject private var appState: AppState
    let profile: Profile
    @Binding var isEditing: Bool
    @Binding var editingName: String
    @State private var noteText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Rename
            HStack(spacing: 6) {
                Image(systemName: "pencil")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                Button("Rename") {
                    editingName = profile.name
                    isEditing = true
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
            }

            Divider()

            // Desktop assignment
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                if appState.store.spaceForProfile(profile.id) != nil {
                    Text("Desktop assigned")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
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
                    Text("No desktop")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("Assign current") {
                        appState.store.assignProfileToCurrentSpace(profileId: profile.id)
                    }
                    .controlSize(.small)
                }
            }

            Divider()

            // Sticky note
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "note.text")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .padding(.top, 4)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Sticky Note")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    TextEditor(text: $noteText)
                    .font(.system(size: 12))
                    .frame(height: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .onAppear { noteText = profile.stickyNote ?? "" }
                    .onChange(of: noteText) {
                        appState.store.setStickyNote(profileId: profile.id, note: noteText)
                    }

                    Text("Shown when switching to this profile")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            // Session actions
            HStack(spacing: 6) {
                Image(systemName: "tray.and.arrow.down")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Session")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        if appState.canRestoreSession(profileId: profile.id) {
                            Button {
                                appState.restoreSession(profileId: profile.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.counterclockwise")
                                    Text("Restore")
                                }
                            }
                            .controlSize(.small)
                        }

                        if SessionSnapshotService.hasRunningApps(profile) {
                            Button {
                                appState.saveAndCloseSession(profileId: profile.id)
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "tray.and.arrow.down")
                                    Text("Save & Close")
                                }
                            }
                            .controlSize(.small)
                        }

                        if !appState.canRestoreSession(profileId: profile.id) &&
                            !SessionSnapshotService.hasRunningApps(profile) {
                            Text("No saved session")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }

            Divider()

            // Layout summary
            HStack(spacing: 6) {
                Image(systemName: "rectangle.3.group")
                    .foregroundStyle(.secondary)
                    .frame(width: 16)

                if let binding = profile.layoutBinding,
                   let template = appState.store.allTemplates.first(where: { $0.id == binding.templateId }) {
                    Text(template.name)
                        .font(.system(size: 12))
                    Text("(\(binding.zoneAssignments.count) zone\(binding.zoneAssignments.count == 1 ? "" : "s"))")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("No layout")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                Text("Configure in Layouts section")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Divider()

            // Hotkey
            ProfileHotkeyRow(profile: profile)
        }
        .padding(12)
        .frame(width: 300)
    }
}

// MARK: - Profile Hotkey Row

private struct ProfileHotkeyRow: View {
    @EnvironmentObject private var appState: AppState
    let profile: Profile

    @State private var shortcut: CustomShortcut?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "keyboard")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            Text("Hotkey:")
                .font(.system(size: 11))
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
                .font(.system(size: 11))
                .controlSize(.small)
            }

            if let conflict = hotkeyConflict {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 10))
                    .help(conflict)
            }
        }
        .padding(.leading, 16)
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
        VStack(alignment: .leading, spacing: 20) {
            // Profile selector
            HStack {
                Text("Profile:")
                    .foregroundStyle(.secondary)
                Text(profile?.name ?? "None")
                    .fontWeight(.medium)
                Spacer()
                profilePicker
            }
            .font(.system(size: 12))

            if let profile {
                LayoutPickerContent(profile: profile)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Create a profile first to configure layouts")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var profilePicker: some View {
        Menu {
            ForEach(appState.store.profiles) { p in
                Button {
                    appState.activateProfile(id: p.id)
                } label: {
                    HStack {
                        Text(p.name)
                        if p.id == appState.store.activeProfileId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Switch")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Shortcuts Section

private struct ShortcutsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Shortcuts")
                    .font(.system(size: 15, weight: .semibold))
                Text("Configure the hotkeys for the app switcher and profile switcher. Hold the modifier, tap the trigger key to cycle, release to switch.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            switcherShortcutSection
            profileShortcutSection
            behaviorSection
            howItWorksSection
        }
    }

    private var switcherShortcutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("App Switcher")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                hotkeyStatusBadge
            }

            // Preset grid — 2 columns
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(ShortcutPreset.allCases) { preset in
                    presetCard(preset)
                }
                customCard
            }

            if appState.shortcutsConflict {
                conflictBanner
            }
        }
    }

    private func presetCard(_ preset: ShortcutPreset) -> some View {
        let isSelected = appState.selectedPreset == preset
        return Button { appState.selectPreset(preset) } label: {
            HStack {
                Text(preset.displayName)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var customCard: some View {
        let isSelected = appState.isCustomAppShortcut
        return Button { appState.selectCustomMode() } label: {
            HStack(spacing: 6) {
                Text("Custom")
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                if isSelected {
                    ShortcutRecorderView(shortcut: $appState.customAppShortcut)
                        .frame(maxWidth: 80)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private var profileShortcutSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Profile Switcher")
                .font(.system(size: 13, weight: .semibold))

            HStack(spacing: 12) {
                if appState.isCustomProfileShortcut {
                    ShortcutRecorderView(shortcut: $appState.customProfileShortcut)
                } else {
                    Text("\(appState.profileShortcutModifierName) + \(appState.profileShortcutKeyName)")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                }
                Toggle("Custom", isOn: $appState.isCustomProfileShortcut)
                    .font(.system(size: 11))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                Spacer()
            }

            if appState.shortcutsConflict {
                conflictBanner
            }
        }
    }

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Behavior")
                .font(.system(size: 13, weight: .semibold))

            Toggle("Move recently switched app to front", isOn: $appState.recentAppFirst)
                .font(.system(size: 12))
        }
    }

    private var howItWorksSection: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                let sel = appState.appShortcutSelection
                shortcutHint("\(sel.modifierName)+\(sel.keyName)", "Show switcher & cycle forward")
                shortcutHint("Shift+\(sel.modifierName)+\(sel.keyName)", "Cycle backward")
                shortcutHint("Release \(sel.modifierName)", "Activate selected")
                shortcutHint("Esc", "Cancel")
                shortcutHint("\u{2318}Q / \u{2318}H / \u{2318}M", "Quit / Hide / Minimize")
                Divider().padding(.vertical, 2)
                shortcutHint("\(appState.profileShortcutModifierName)+\(appState.profileShortcutKeyName)", "Show profile switcher")
            }
            .padding(.top, 6)
        } label: {
            Text("Quick Reference")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private func shortcutHint(_ keys: String, _ description: String) -> some View {
        HStack(spacing: 8) {
            Text(keys)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(width: 160, alignment: .leading)
            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private var hotkeyStatusBadge: some View {
        HStack(spacing: 4) {
            switch appState.hotkeyStatus {
            case .running:
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Active").font(.system(size: 10)).foregroundStyle(.green)
            case .failed:
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                Text("No access").font(.system(size: 10)).foregroundStyle(.orange)
            case .stopped:
                Circle().fill(Color.gray).frame(width: 6, height: 6)
                Text("Stopped").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }

    private var conflictBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("App and profile shortcuts conflict \u{2014} app switcher takes priority.")
        }
        .font(.system(size: 11))
        .foregroundStyle(.orange)
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var hotkeyStatusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
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
            .font(.system(size: 12))

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

    private let shortcutGroups: [(title: String, directions: [SnapDirection])] = [
        ("Halves", [.left, .right, .topHalf, .bottomHalf]),
        ("Quarters", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ("Thirds", [.firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds]),
        ("Other", [.full, .center]),
        ("Cycle", [.cycleNext, .cyclePrevious]),
        ("Monitors", [.nextMonitor, .previousMonitor]),
        ("Actions", [.undo]),
    ]

    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Drag to Snap toggle
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Drag to Snap", isOn: $appState.dragSnapEnabled)
                    .font(.system(size: 13, weight: .semibold))
                Text("Drag any window to a screen edge or corner to snap it into position.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Gap — compact inline
            VStack(alignment: .leading, spacing: 8) {
                Text("Window Gap")
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 12) {
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
                        .onChange(of: gapSize) {
                            UserDefaults.standard.set(gapSize, forKey: "windowGap")
                        }

                    Text("\(Int(gapSize)) pt")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(width: 35)
                }
            }

            // Snap shortcuts
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Snap Shortcuts")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button("Reset") {
                        snapConfig = .defaults
                        saveConfig()
                    }
                    .controlSize(.mini)
                    .foregroundStyle(.secondary)
                }
                Text("Global hotkeys to snap windows. Press the same key twice to cycle sizes.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                ForEach(shortcutGroups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .tracking(0.5)
                            .padding(.top, 6)

                        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                            ForEach(group.directions, id: \.self) { direction in
                                snapShortcutRow(direction: direction)
                            }
                        }
                    }
                }
            }
        }
    }

    private func snapShortcutRow(direction: SnapDirection) -> some View {
        HStack(spacing: 4) {
            Text(direction.displayName)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            ShortcutRecorderView(shortcut: binding(for: direction))
                .frame(width: 80)

            if snapConfig.bindings[direction] != nil {
                Button {
                    snapConfig.bindings.removeValue(forKey: direction)
                    saveConfig()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 10))
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
}

// MARK: - Window Rules Section

private struct WindowRulesSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Window Rules")
                .font(.system(size: 15, weight: .semibold))
            Text("Set a rule like \"Chrome → Left Half on launch\" and it will always open there. Great for keeping your workspace consistent without manually snapping every time.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            if let provider = ProServiceRegistry.shared.provider,
               let view = provider.windowsSectionView() {
                view
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.yellow)
                    Text("Available with HopTab Pro")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Link("Learn more", destination: URL(string: "https://buy.polar.sh/polar_cl_iKgZQ7w4AWRhnNzsnQBl80syKnFJGHJj1Pv6d2a9tD7")!)
                        .font(.system(size: 12))
                }
            }
        }
    }
}

// MARK: - Pro Section

private struct ProSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HopTab Pro")
                            .font(.system(size: 18, weight: .bold))
                        Text("Automate your workspace — let HopTab work for you.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }

                if ProServiceRegistry.shared.isLicensed {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Text("Pro Active")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.green)
                    }
                    .padding(.top, 4)
                } else {
                    Link(destination: URL(string: "https://buy.polar.sh/polar_cl_iKgZQ7w4AWRhnNzsnQBl80syKnFJGHJj1Pv6d2a9tD7")!) {
                        Text("Unlock Pro — $5 one-time")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor))
                    }
                    .padding(.top, 4)

                    Link(destination: URL(string: "https://github.com/sponsors/royalbhati")!) {
                        Text("or sponsor on GitHub")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // Feature list
            proFeature(
                icon: "clock.fill", color: .blue,
                title: "Time Tracking",
                description: "See exactly how long you spend in each profile. Zero effort — works automatically from profile switches."
            )

            proFeature(
                icon: "calendar", color: .red,
                title: "Calendar Auto-Switch",
                description: "\"Daily Standup\" starts → switches to Meeting profile. Detects Zoom, Teams, Meet links. Fullscreen reminder with Join button."
            )

            proFeature(
                icon: "clock.badge", color: .orange,
                title: "Time Schedule",
                description: "\"At 7 PM switch to Entertainment\" — set it once, works every day. Filter by weekday."
            )

            proFeature(
                icon: "moon.fill", color: .purple,
                title: "Focus Mode Integration",
                description: "Enable \"Work\" Focus → auto-switches to your Work profile. Assign multiple profiles per Focus mode."
            )

            proFeature(
                icon: "display", color: .cyan,
                title: "Display Auto-Profiles",
                description: "Plug in your external monitor → auto-switches to \"Docked\" profile. Unplug → switches to \"Laptop\"."
            )

            proFeature(
                icon: "rectangle.badge.plus", color: .green,
                title: "Window Rules",
                description: "\"VS Code always left 60%\" — set once, auto-snaps on every launch or focus. Free tier gets 2 rules."
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

            Divider()

            // v2 Pro Features
            proFeature(
                icon: "arrow.uturn.backward.circle.fill", color: .blue,
                title: "Window Undo",
                description: "Undo any window move or resize. Full history — step back through your last 50 window operations."
            )

            proFeature(
                icon: "wind", color: .green,
                title: "Auto-Declutter",
                description: "Windows you haven't touched in 30+ minutes get auto-minimized. One-click clean up or fully automatic."
            )

            proFeature(
                icon: "pip.fill", color: .pink,
                title: "PiP for Any Window",
                description: "Pin any window as a floating mini-preview. Watch a video, monitor Slack, or keep a terminal visible while working."
            )

            proFeature(
                icon: "brain.head.profile.fill", color: .purple,
                title: "Smart Placement",
                description: "Learns where you place windows and auto-positions new ones based on your habits. Zero configuration."
            )

            proFeature(
                icon: "sun.min.fill", color: .orange,
                title: "Focus Dimming",
                description: "Dim background windows so you can focus on what matters. The active app stays bright, everything else fades."
            )

            proFeature(
                icon: "eye.slash.fill", color: .teal,
                title: "Screen Breaks",
                description: "Workspace-aware break reminders. Saves your window state, shows a break screen, restores everything when you return."
            )

            // v2 Pro Config (shown when licensed)
            if ProServiceRegistry.shared.isLicensed,
               let provider = ProServiceRegistry.shared.provider {
                Divider()
                provider.proFeaturesView()
            }

            // License entry
            if let provider = ProServiceRegistry.shared.provider {
                Divider()
                provider.licenseSectionView()
            }

            // Student/affordability note
            if !ProServiceRegistry.shared.isLicensed {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("Can't afford it?")
                        .font(.system(size: 12, weight: .medium))
                    Text("If you're a student or really think these features can make your life better but can't afford $5 — send me an email and I'll give you Pro for free. No questions asked.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Link("rawyelll@gmail.com", destination: URL(string: "mailto:rawyelll@gmail.com?subject=HopTab%20Pro%20Request")!)
                        .font(.system(size: 11))
                }
            }
        }
    }

    private func proFeature(icon: String, color: Color, title: String, description: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(color.opacity(0.12))
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Displays Section (Pro only)

private struct DisplaysSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Displays")
                .font(.system(size: 13, weight: .semibold))

            if let provider = ProServiceRegistry.shared.provider {
                provider.displaysSectionView(profiles: appState.store.profiles.map { ProProfileInfo(id: $0.id, name: $0.name) })
            }
        }
    }
}

// MARK: - About Section

private struct AboutSection: View {
    @EnvironmentObject private var appState: AppState
    @StateObject private var updateService = UpdateService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // App identity
            VStack(spacing: 12) {
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
            }
            .frame(maxWidth: .infinity)

            Divider()

            // Onboarding
            Button {
                UserDefaults.standard.set(false, forKey: "hasCompletedOnboarding")
                NSApp.sendAction(#selector(AppDelegate.showOnboarding(_:)), to: nil, from: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "book.pages")
                    Text("Show Onboarding")
                }
            }
            .controlSize(.small)

            // Update section
            VStack(alignment: .leading, spacing: 10) {
                Text("Updates")
                    .font(.system(size: 13, weight: .semibold))

                VStack(spacing: 8) {
                    HStack {
                        Toggle("Check for updates automatically", isOn: $updateService.autoCheckEnabled)
                            .font(.system(size: 12))
                        Spacer()
                    }

                    HStack {
                        Button {
                            Task { await updateService.checkForUpdates(silent: false) }
                        } label: {
                            HStack(spacing: 4) {
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
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.down.circle.fill")
                                    Text("v\(update.version) Available")
                                }
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(6)
            }

            // Pro license section
            if let provider = ProServiceRegistry.shared.provider {
                provider.licenseSectionView()
            }

            Spacer()
        }
    }
}

// MARK: - Notification

extension Notification.Name {
    static let snapShortcutsChanged = Notification.Name("snapShortcutsChanged")
}
