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
        .frame(width: 480, height: 450)
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

            // Running apps — click row to toggle pin
            GroupBox("Running Apps \u{2014} click to pin / unpin") {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Filter running apps\u{2026}", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                .padding(.bottom, 4)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(appState.runningApps.filter { app in
                            guard !searchText.isEmpty,
                                  let name = app.localizedName else { return true }
                            return fuzzyMatch(query: searchText, target: name)
                        }, id: \.bundleIdentifier) { app in
                            if let bundleID = app.bundleIdentifier,
                               let name = app.localizedName {
                                let pinned = appState.store.isPinned(bundleID)
                                HStack {
                                    if let icon = app.icon {
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
                                    appState.store.togglePin(
                                        bundleIdentifier: bundleID,
                                        displayName: name
                                    )
                                }
                            }
                        }
                    }
                }
                .frame(minHeight: 80, maxHeight: 150)
            }
        }
        .padding()
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
    @State private var editingProfileId: UUID?
    @State private var editingName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Profiles") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Create profiles for different workflows. Each profile has its own set of pinned apps. Assign a profile to a desktop and it auto-activates when you switch there.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 4)

                    List {
                        ForEach(appState.store.profiles) { profile in
                            VStack(alignment: .leading, spacing: 4) {
                                if editingProfileId == profile.id {
                                    HStack {
                                        TextField("Profile name", text: $editingName, onCommit: {
                                            commitRename(id: profile.id)
                                        })
                                        .textFieldStyle(.roundedBorder)
                                        .frame(maxWidth: 200)

                                        Button("Save") { commitRename(id: profile.id) }
                                            .buttonStyle(.borderedProminent)
                                            .controlSize(.small)

                                        Button("Cancel") { editingProfileId = nil }
                                            .controlSize(.small)
                                    }
                                } else {
                                    HStack {
                                        Image(systemName: profile.id == appState.store.activeProfileId ? "circle.fill" : "circle")
                                            .foregroundStyle(profile.id == appState.store.activeProfileId ? Color.accentColor : .secondary)
                                            .font(.system(size: 8))

                                        Text(profile.name)
                                            .fontWeight(profile.id == appState.store.activeProfileId ? .semibold : .regular)

                                        Text("\(profile.pinnedApps.count) app\(profile.pinnedApps.count == 1 ? "" : "s")")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)

                                        Spacer()

                                        if profile.id == appState.store.activeProfileId {
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
                                            editingProfileId = profile.id
                                            editingName = profile.name
                                        } label: {
                                            Image(systemName: "pencil")
                                        }
                                        .buttonStyle(.plain)
                                        .foregroundStyle(.secondary)

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

                                    // Desktop assignment row
                                    HStack(spacing: 4) {
                                        Image(systemName: "desktopcomputer")
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)

                                        if appState.store.spaceForProfile(profile.id) != nil {
                                            Text("Assigned to a desktop")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.secondary)
                                            Button("Reassign to this desktop") {
                                                appState.store.assignProfileToCurrentSpace(profileId: profile.id)
                                            }
                                            .font(.system(size: 11))
                                            .controlSize(.small)
                                            Button("Remove") {
                                                appState.store.unassignProfileFromSpace(profileId: profile.id)
                                            }
                                            .font(.system(size: 11))
                                            .controlSize(.small)
                                            .foregroundStyle(.red.opacity(0.7))
                                        } else {
                                            Text("No desktop assigned")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.tertiary)
                                            Button("Assign to this desktop") {
                                                appState.store.assignProfileToCurrentSpace(profileId: profile.id)
                                            }
                                            .font(.system(size: 11))
                                            .controlSize(.small)
                                        }
                                    }
                                    .padding(.leading, 16)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .frame(minHeight: 120, maxHeight: 250)
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

    private func commitRename(id: UUID) {
        let name = editingName.trimmingCharacters(in: .whitespaces)
        if !name.isEmpty {
            appState.store.renameProfile(id: id, to: name)
        }
        editingProfileId = nil
    }
}

// MARK: - Shortcut Tab

private struct ShortcutTab: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            GroupBox("Switcher Shortcut") {
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Shortcut", selection: $appState.selectedShortcut) {
                        ForEach(ShortcutPreset.allCases) { preset in
                            Text(preset.displayName).tag(preset)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Divider()

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
                .padding(8)
            }

            GroupBox("Behavior") {
                Toggle("Move recently switched app to front", isOn: $appState.recentAppFirst)
                    .font(.system(size: 12))
                    .padding(8)
            }

            GroupBox("How It Works") {
                VStack(alignment: .leading, spacing: 6) {
                    let preset = appState.selectedShortcut
                    Label("\(preset.modifierName) + \(preset.keyName) \u{2014} show switcher & cycle forward",
                          systemImage: "arrow.right")
                    Label("Shift + \(preset.modifierName) + \(preset.keyName) \u{2014} cycle backward",
                          systemImage: "arrow.left")
                    Label("Release \(preset.modifierName) \u{2014} activate selected app",
                          systemImage: "checkmark")
                    Label("Escape \u{2014} cancel",
                          systemImage: "xmark")
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(8)
            }

            Spacer()
        }
        .padding()
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

            Text("Version 1.0")
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
