import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        TabView {
            PinnedAppsTab()
                .tabItem {
                    Label("Pinned Apps", systemImage: "pin.fill")
                }

            ProfilesTab()
                .tabItem {
                    Label("Profiles", systemImage: "person.2.fill")
                }

            ShortcutTab()
                .tabItem {
                    Label("Shortcut", systemImage: "keyboard")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 480, height: 520)
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

// MARK: - Pinned Apps Tab

private struct PinnedAppsTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var searchText = ""
    @State private var appSource: AppSource = .running

    enum AppSource: String, CaseIterable {
        case running = "Running"
        case allApps = "All Apps"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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
            GroupBox("Pinned Apps") {
                if appState.store.apps.isEmpty {
                    Text("No apps pinned yet. Add apps from the list below.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 40)
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
            GroupBox {
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
            } label: {
                Text(appSource == .running
                     ? "Running Apps \u{2014} click to pin / unpin"
                     : "All Apps \u{2014} click to pin / unpin")
            }
        }
        .padding()
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
                    appState.store.setActiveProfile(id: profile.id)
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

// MARK: - Profiles Tab

private struct ProfilesTab: View {
    @EnvironmentObject private var appState: AppState
    @State private var newProfileName = ""
    @State private var settingsProfileId: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Profiles") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create profiles for different workflows. Click the gear icon to configure desktop assignment and hotkey.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)

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
                    .frame(minHeight: 120, maxHeight: 300)
                }
                .padding(4)
            }

            GroupBox("New Profile") {
                HStack {
                    TextField("Profile name", text: $newProfileName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { addProfile() }

                    Button("Add") { addProfile() }
                        .disabled(newProfileName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(4)
            }

            Spacer()
        }
        .padding()
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
                            appState.store.setActiveProfile(id: profile.id)
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
                            appState.store.deleteProfile(id: profile.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.red.opacity(0.7))
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

// MARK: - Shortcut Tab

private struct ShortcutTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                switcherShortcutSection
                profileShortcutSection
                behaviorSection
                howItWorksSection
            }
            .padding()
        }
    }

    private var switcherShortcutSection: some View {
        GroupBox("Switcher Shortcut") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(ShortcutPreset.allCases) { preset in
                    HStack(spacing: 8) {
                        Image(systemName: appState.selectedPreset == preset ? "circle.inset.filled" : "circle")
                            .foregroundStyle(appState.selectedPreset == preset ? Color.accentColor : .secondary)
                            .font(.system(size: 14))
                        Text(preset.displayName)
                            .font(.system(size: 13))
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { appState.selectPreset(preset) }
                }

                HStack(spacing: 8) {
                    Image(systemName: appState.isCustomAppShortcut ? "circle.inset.filled" : "circle")
                        .foregroundStyle(appState.isCustomAppShortcut ? Color.accentColor : .secondary)
                        .font(.system(size: 14))
                    Text("Custom")
                        .font(.system(size: 13))

                    if appState.isCustomAppShortcut {
                        ShortcutRecorderView(shortcut: $appState.customAppShortcut)
                    }

                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { appState.selectCustomMode() }

                if appState.shortcutsConflict {
                    conflictBanner
                }

                Divider()

                hotkeyStatusRow
            }
            .padding(8)
        }
    }

    private var profileShortcutSection: some View {
        GroupBox("Profile Switcher Shortcut") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Custom shortcut", isOn: $appState.isCustomProfileShortcut)
                    .font(.system(size: 12))

                if appState.isCustomProfileShortcut {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(.secondary)
                        ShortcutRecorderView(shortcut: $appState.customProfileShortcut)
                    }
                    .font(.system(size: 12))
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(.secondary)
                        Text("\(appState.profileShortcutModifierName) + \(appState.profileShortcutKeyName)")
                            .fontWeight(.medium)
                        Text("(auto-configured)")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 12))
                }

                if appState.shortcutsConflict {
                    conflictBanner
                }
            }
            .padding(8)
        }
    }

    private var behaviorSection: some View {
        GroupBox("Behavior") {
            Toggle("Move recently switched app to front", isOn: $appState.recentAppFirst)
                .font(.system(size: 12))
                .padding(8)
        }
    }

    private var howItWorksSection: some View {
        GroupBox("How It Works") {
            VStack(alignment: .leading, spacing: 6) {
                let sel = appState.appShortcutSelection
                Text("App Switcher")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Label("\(sel.modifierName) + \(sel.keyName) \u{2014} show switcher & cycle forward",
                      systemImage: "arrow.right")
                Label("Shift + \(sel.modifierName) + \(sel.keyName) \u{2014} cycle backward",
                      systemImage: "arrow.left")
                Label("Release \(sel.modifierName) \u{2014} activate selected app",
                      systemImage: "checkmark")
                Label("Escape \u{2014} cancel",
                      systemImage: "xmark")
                Label("\u{2318}Q \u{2014} quit highlighted app",
                      systemImage: "xmark.circle")
                Label("\u{2318}H \u{2014} hide highlighted app",
                      systemImage: "eye.slash")
                Label("\u{2318}M \u{2014} minimize highlighted app",
                      systemImage: "minus.rectangle")

                Divider().padding(.vertical, 2)

                Text("Profile Switcher")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Label("\(appState.profileShortcutModifierName) + \(appState.profileShortcutKeyName) \u{2014} show profiles & cycle forward",
                      systemImage: "arrow.right")
                Label("Shift + \(appState.profileShortcutModifierName) + \(appState.profileShortcutKeyName) \u{2014} cycle backward",
                      systemImage: "arrow.left")
                Label("Release \(appState.profileShortcutModifierName) \u{2014} activate selected profile",
                      systemImage: "checkmark")
                Label("Escape \u{2014} cancel",
                      systemImage: "xmark")
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(8)
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

// MARK: - About Tab

private struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "pin.circle.fill")
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

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
