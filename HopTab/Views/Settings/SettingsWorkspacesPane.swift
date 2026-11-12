import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Workspaces pane

/// Master-detail in one Form: a chip row picks the workspace, everything
/// below edits that one workspace — its apps, layout and behaviour. Replaces
/// the old profile list + separate "Profile" picker + pinned-apps list, which
/// showed the same choice three times on one page.
struct WorkspacesPane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var nav = SettingsNavigation.shared

    private var selected: Profile? {
        let profiles = appState.store.profiles
        if let id = nav.selectedWorkspaceId, let p = profiles.first(where: { $0.id == id }) { return p }
        return appState.store.activeProfile ?? profiles.first
    }

    var body: some View {
        Section {
            WorkspaceChips(selectedId: Binding(
                get: { selected?.id },
                set: { nav.selectedWorkspaceId = $0 }
            ))
        }

        if let profile = selected {
            WorkspaceHeaderSection(profile: profile)
            WorkspaceAppsSection(profile: profile)
            Section {
                LayoutPickerContent(profile: profile)
            } header: {
                Text("Layout")
            } footer: {
                Text("Assign apps to zones. Applied when the workspace activates, or from the menu bar.")
            }
            Section {
                ProfileDetailView(profile: profile)
            } header: {
                Text("Behaviour")
            }
        } else {
            Section {
                VStack(spacing: HopSpacing.sm) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("No workspaces yet")
                        .font(.hopSubheading)
                    Text("A workspace is a named set of apps with its own layout and hotkey. Add one above, or use \u{201C}New workspace from what\u{2019}s open\u{201D} in the menu bar.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HopSpacing.lg)
            }
        }
    }
}

// MARK: - Workspace chips

private struct WorkspaceChips: View {
    @EnvironmentObject private var appState: AppState
    @Binding var selectedId: UUID?
    @State private var isAdding = false
    @State private var newName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HopSpacing.sm) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: HopSpacing.xs + 2) {
                    ForEach(appState.store.profiles) { profile in
                        chip(profile)
                    }
                    addChip
                }
                .padding(.vertical, 2)
            }
            if isAdding {
                HStack(spacing: HopSpacing.sm) {
                    TextField("Workspace name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .frame(maxWidth: 260)
                        .onSubmit(commitAdd)
                    Button("Add", action: commitAdd)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Cancel") { isAdding = false; newName = "" }
                        .controlSize(.small)
                }
                .transition(.opacity)
            }
        }
        .animation(HopMotion.snappy, value: isAdding)
    }

    private func chip(_ profile: Profile) -> some View {
        let isSelected = profile.id == selectedId
        let isActive = profile.id == appState.store.activeProfileId
        return Button {
            selectedId = profile.id
        } label: {
            HStack(spacing: HopSpacing.xs) {
                if isActive {
                    Circle()
                        .fill(isSelected ? Color.white : Color.accentColor)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(profile.name)
                    .lineLimit(1)
                Text("\(profile.pinnedApps.count)")
                    .font(.hopFootnote.monospacedDigit())
                    .opacity(0.7)
            }
            .font(.hopSubheading.weight(isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, HopSpacing.md)
            .padding(.vertical, HopSpacing.xs + 2)
            .background(
                Capsule().fill(isSelected ? Color.accentColor : Color.primary.opacity(0.07))
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(profile.name), \(profile.pinnedApps.count) apps\(isActive ? ", active" : "")")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var addChip: some View {
        let canAdd = appState.store.canAddProfile
        return Button {
            if canAdd {
                isAdding = true
                DispatchQueue.main.async { nameFocused = true }
            }
        } label: {
            Label(canAdd ? "New" : "Pro for more", systemImage: canAdd ? "plus" : "lock")
                .font(.hopSubheading)
                .foregroundStyle(canAdd ? Color.accentColor : Color.secondary)
                .padding(.horizontal, HopSpacing.md)
                .padding(.vertical, HopSpacing.xs + 2)
                .background(
                    Capsule().strokeBorder(Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!canAdd)
        .help(canAdd ? "Add a workspace" : "The free tier allows \(ProFeatureGate.freeProfileLimit) workspaces.")
    }

    private func commitAdd() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        appState.store.addProfile(name: name)
        if let created = appState.store.profiles.last { selectedId = created.id }
        newName = ""
        isAdding = false
    }
}

// MARK: - Workspace header (name, activate, hotkey, delete)

private struct WorkspaceHeaderSection: View {
    @EnvironmentObject private var appState: AppState
    let profile: Profile

    @State private var name = ""
    @State private var confirmDelete = false

    private var isActive: Bool { profile.id == appState.store.activeProfileId }

    var body: some View {
        Section {
            HStack(spacing: HopSpacing.md) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                            .fill(isActive ? HopColor.tint(Color.accentColor) : Color.primary.opacity(0.05))
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    TextField("Workspace name", text: $name)
                        .textFieldStyle(.plain)
                        .labelsHidden()
                        .font(.title3.weight(.semibold))
                        .onSubmit(commitRename)
                        .accessibilityLabel("Workspace name")
                    Text(summary)
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if isActive {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.hopCaption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, HopSpacing.sm + 2)
                        .padding(.vertical, HopSpacing.xs)
                        .background(Capsule().fill(HopColor.tint(Color.accentColor)))
                } else {
                    Button("Activate") { appState.activateProfile(id: profile.id) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }

                if appState.store.profiles.count > 1 {
                    Menu {
                        Button("Delete \u{201C}\(profile.name)\u{201D}\u{2026}", role: .destructive) { confirmDelete = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More actions for \(profile.name)")
                }
            }
            .padding(.vertical, HopSpacing.xs)

            ProfileHotkeyRow(profile: profile)
        } footer: {
            Text("Press the hotkey anywhere to switch here. The name saves on Return.")
        }
        .onAppear { name = profile.name }
        .onChange(of: profile.id) { name = profile.name }
        .onChange(of: profile.name) { if name != profile.name { name = profile.name } }
        .alert("Delete \u{201C}\(profile.name)\u{201D}?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                appState.store.deleteProfile(id: profile.id)
                SettingsNavigation.shared.selectedWorkspaceId = nil
            }
        } message: {
            Text("Its pinned apps, layout assignment and saved sessions go with it.")
        }
    }

    private var summary: String {
        let running = profile.pinnedApps.filter(\.isRunning).count
        let total = profile.pinnedApps.count
        var parts = ["\(total) app\(total == 1 ? "" : "s")"]
        if total > 0 { parts.append("\(running) running") }
        if appState.store.spaceForProfile(profile.id) != nil { parts.append("desktop assigned") }
        if let bp = profile.browserProfile { parts.append(bp.displayName) }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func commitRename() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profile.name else { name = profile.name; return }
        appState.store.renameProfile(id: profile.id, to: trimmed)
    }
}

// MARK: - Workspace apps (pinned list + add)

private struct WorkspaceAppsSection: View {
    @EnvironmentObject private var appState: AppState
    let profile: Profile

    @State private var searchText = ""
    @State private var appSource: AppSource = .running
    @State private var pendingRemoval: PinnedApp?

    enum AppSource: String, CaseIterable {
        case running = "Running"
        case allApps = "All Apps"
    }

    private static let pinnedRowHeight: CGFloat = 36

    var body: some View {
        Section {
            if profile.pinnedApps.isEmpty {
                VStack(spacing: HopSpacing.xs) {
                    Text("No apps yet")
                        .font(.hopSubheading.weight(.medium))
                    Text("Add some below, or press P on any app in the switcher.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HopSpacing.md)
            } else {
                List {
                    ForEach(profile.pinnedApps) { app in
                        pinnedRow(app)
                            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                            .listRowSeparator(.hidden)
                    }
                    .onMove { source, destination in
                        appState.store.move(from: source, to: destination, inProfile: profile.id)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollDisabled(true)
                .frame(height: CGFloat(profile.pinnedApps.count) * Self.pinnedRowHeight)
            }
        } header: {
            HStack {
                Text("Apps")
                Spacer()
                if !profile.pinnedApps.isEmpty {
                    Text("\(profile.pinnedApps.count)")
                        .font(.hopCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("Shown first in the switcher, in this order. Drag to reorder.")
        }
        .alert(
            "Remove \(pendingRemoval?.displayName ?? "app") from \(profile.name)?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })
        ) {
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
            Button("Remove", role: .destructive) {
                if let app = pendingRemoval {
                    appState.store.remove(bundleIdentifier: app.bundleIdentifier, fromProfile: profile.id)
                }
                pendingRemoval = nil
            }
        } message: {
            Text("Its display assignment and launch options for this workspace are removed too.")
        }

        Section {
            HStack(spacing: HopSpacing.sm) {
                HStack(spacing: HopSpacing.xs) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Search apps\u{2026}", text: $searchText)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Filter apps to add")
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
                }
                .padding(.horizontal, HopSpacing.sm)
                .padding(.vertical, HopSpacing.xs + 1)
                .background(
                    RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                Picker("Source", selection: $appSource) {
                    ForEach(AppSource.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("App list source")
            }

            let rows = candidateRows
            if rows.isEmpty {
                Text(searchText.isEmpty ? "Nothing to add." : "No app matches \u{201C}\(searchText)\u{201D}.")
                    .font(.hopCaption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, HopSpacing.md)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: HopSpacing.xs)], spacing: 2) {
                        ForEach(rows) { row in
                            appRow(bundleID: row.id, name: row.name, icon: row.icon)
                        }
                    }
                }
                .frame(minHeight: 80, maxHeight: 260)
            }
        } header: {
            Text("Add apps")
        } footer: {
            Text(appSource == .running
                 ? "Apps open right now. Switch to All Apps for everything installed."
                 : "Everything in your Applications folders.")
        }
        .onAppear { if appSource == .allApps { appState.ensureInstalledAppsLoaded() } }
        .onChange(of: appSource) { if appSource == .allApps { appState.ensureInstalledAppsLoaded() } }
    }

    private struct CandidateRow: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
    }

    private var candidateRows: [CandidateRow] {
        if appSource == .running {
            return filteredRunningApps.compactMap { app in
                guard let bundleID = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return CandidateRow(id: bundleID, name: name, icon: app.icon)
            }
        }
        return filteredInstalledApps.map { CandidateRow(id: $0.bundleIdentifier, name: $0.displayName, icon: $0.icon) }
    }

    private func pinnedRow(_ app: PinnedApp) -> some View {
        HStack(spacing: HopSpacing.sm + 2) {
            Image(systemName: "line.3.horizontal")
                .font(.hopCaption)
                .foregroundStyle(.quaternary)
                .accessibilityHidden(true)
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(app.displayName)
                    .lineLimit(1)
                Text(app.isRunning ? "Running" : "Not running")
                    .font(.hopFootnote)
                    .foregroundStyle(app.isRunning ? HopColor.runningIndicator : Color.secondary)
            }

            Spacer(minLength: HopSpacing.sm)

            if NSScreen.screens.count > 1 || app.assignedDisplay != nil {
                Picker("Display", selection: Binding(
                    get: { app.assignedDisplay },
                    set: { appState.store.setDisplayAssignment(bundleIdentifier: app.bundleIdentifier, displayName: $0, inProfile: profile.id) }
                )) {
                    Text("Any display").tag(String?.none)
                    ForEach(displayOptions, id: \.id) { option in
                        Text(option.label).tag(String?.some(option.name))
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(minWidth: 120, idealWidth: 150)
                .accessibilityLabel("Display assignment for \(app.displayName)")
            }

            Button(role: .destructive) {
                pendingRemoval = app
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(app.displayName) from \(profile.name)")
        }
        .frame(height: Self.pinnedRowHeight)
        .contentShape(Rectangle())
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
        let mine = Bundle.main.bundleIdentifier
        return appState.runningApps.filter { app in
            guard app.bundleIdentifier != mine else { return false }
            guard !searchText.isEmpty, let name = app.localizedName else { return true }
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
        let pinned = appState.store.isPinned(bundleID, inProfile: profile.id)
        return Button {
            appState.store.togglePin(bundleIdentifier: bundleID, displayName: name, inProfile: profile.id)
        } label: {
            HStack {
                if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                        .accessibilityHidden(true)
                }
                Text(name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: HopSpacing.xs)
                Image(systemName: pinned ? "checkmark.circle.fill" : "plus.circle")
                    .foregroundStyle(pinned ? Color.accentColor : .secondary)
                    .accessibilityHidden(true)
            }
            .padding(.vertical, HopSpacing.xs + 1)
            .padding(.horizontal, HopSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                    .fill(pinned ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(pinned ? "Remove \(name) from \(profile.name)" : "Add \(name) to \(profile.name)")
    }
}

// MARK: - Workspace behaviour (sticky note, desktop, session, launch order)

struct ProfileDetailView: View {
    @EnvironmentObject private var appState: AppState
    let profile: Profile

    @State private var noteText: String = ""
    @State private var noteSaveTask: Task<Void, Never>?
    @State private var confirmUnassignDesktop = false
    @State private var confirmSaveAndClose = false

    var body: some View {
        VStack(alignment: .leading, spacing: HopSpacing.md) {
            // Sticky note — front and center for discoverability.
            VStack(alignment: .leading, spacing: HopSpacing.xs) {
                Label("Sticky Note", systemImage: "note.text")
                    .font(.hopSubheading)
                    .foregroundStyle(.secondary)
                TextEditor(text: $noteText)
                    .font(.body)
                    .frame(minHeight: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                    .accessibilityLabel("Sticky note for \(profile.name)")
                Text("Shown when switching to this workspace")
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
                    Button("Remove\u{2026}") {
                        confirmUnassignDesktop = true
                    }
                    .controlSize(.small)
                    .foregroundStyle(HopColor.danger)
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
            .alert("Remove desktop assignment?", isPresented: $confirmUnassignDesktop) {
                Button("Cancel", role: .cancel) {}
                Button("Remove", role: .destructive) {
                    appState.store.unassignProfileFromSpace(profileId: profile.id)
                }
            } message: {
                Text("\u{201C}\(profile.name)\u{201D} will stop jumping to its desktop when you switch to it. macOS gives no way to look a desktop up again, so you would have to be standing on it to reassign.")
            }

            // Browser profile tied to this workspace
            BrowserProfilePicker(profile: profile)

            // Windows-to-desktop move (only meaningful with a desktop assigned)
            VStack(alignment: .leading, spacing: HopSpacing.xs) {
                Toggle("Move windows to this desktop", isOn: Binding(
                    get: { appState.store.movesWindowsToAssignedSpace(profile.id) },
                    set: { appState.store.setMoveWindowsToAssignedSpace(profileId: profile.id, enabled: $0) }
                ))
                .disabled(appState.store.spaceForProfile(profile.id) == nil)
                Text(appState.store.spaceForProfile(profile.id) == nil
                     ? "Assign a desktop first. When on, switching to this workspace also moves its apps' windows onto that desktop."
                     : "When switching to this workspace, its apps' windows are moved onto the assigned desktop instead of only hiding other apps.")
                    .font(.hopFootnote)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if appState.spaceMoveUnsupported && appState.store.movesWindowsToAssignedSpace(profile.id) {
                    HStack(spacing: HopSpacing.xs) {
                        Image(systemName: "exclamationmark.triangle")
                            .accessibilityHidden(true)
                        Text("Not supported on this macOS version \u{2014} HopTab falls back to hiding other apps.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.hopFootnote)
                    .foregroundStyle(HopColor.warning)
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
                            confirmSaveAndClose = true
                        } label: {
                            Label("Save & Close\u{2026}", systemImage: "tray.and.arrow.down")
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
            .alert("Save the session and quit these apps?", isPresented: $confirmSaveAndClose) {
                Button("Cancel", role: .cancel) {}
                Button("Save & Close", role: .destructive) {
                    appState.saveAndCloseSession(profileId: profile.id)
                }
            } message: {
                Text("HopTab records each window's position, then quits every running app pinned to \u{201C}\(profile.name)\u{201D}. Unsaved work in those apps may prompt or be lost.")
            }

            // Launch order — per-app options for Restore Session
            if !profile.pinnedApps.isEmpty {
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: HopSpacing.xs) {
                        ForEach(profile.pinnedApps, id: \.bundleIdentifier) { app in
                            LaunchOptionsRow(profileId: profile.id, app: app)
                        }
                        Text("Lower launch order goes first. Delay staggers an app within its group. \u{201C}Open on restore\u{201D} lets an app start with a file, folder, or URL.")
                            .font(.hopFootnote)
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, HopSpacing.xs)
                } label: {
                    Label("Launch order", systemImage: "list.number")
                        .foregroundStyle(.secondary)
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

struct LaunchOptionsRow: View {
    @EnvironmentObject private var appState: AppState
    let profileId: UUID
    let app: PinnedApp

    /// 0 means "no explicit order" — launches in the trailing group.
    @State private var priority: Int = 0
    /// Seconds. 0 means no extra delay.
    @State private var delay: Double = 0
    @State private var urls: [String] = []
    @State private var skip: Bool = false
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: HopSpacing.sm) {
                LabeledContent("Launch order") {
                    Stepper(value: $priority, in: 0...50) {
                        Text(priority == 0 ? "Last" : "\(priority)")
                            .font(.hopSubheading.monospacedDigit())
                            .frame(minWidth: 44, alignment: .leading)
                    }
                    .accessibilityLabel("Launch order for \(app.displayName)")
                    .accessibilityValue(priority == 0 ? "Last" : "\(priority)")
                }

                LabeledContent("Delay before launching") {
                    Stepper(value: $delay, in: 0...120, step: 0.5) {
                        Text(delay == 0 ? "None" : String(format: "%.1f s", delay))
                            .font(.hopSubheading.monospacedDigit())
                            .frame(minWidth: 60, alignment: .leading)
                    }
                    .accessibilityLabel("Launch delay for \(app.displayName)")
                    .accessibilityValue(delay == 0 ? "None" : "\(delay) seconds")
                }

                VStack(alignment: .leading, spacing: HopSpacing.xs) {
                    HStack {
                        Text("Open on restore")
                            .font(.hopSubheading)
                        Spacer()
                        Button {
                            chooseFiles()
                        } label: {
                            Label("Choose File\u{2026}", systemImage: "folder")
                        }
                        .controlSize(.small)
                        Button {
                            addURLPlaceholder()
                        } label: {
                            Label("Add URL", systemImage: "link")
                        }
                        .controlSize(.small)
                    }

                    if urls.isEmpty {
                        Text("Nothing \u{2014} the app just launches.")
                            .font(.hopCaption)
                            .foregroundStyle(.tertiary)
                    } else {
                        ForEach(Array(urls.enumerated()), id: \.offset) { index, _ in
                            HStack(spacing: HopSpacing.xs) {
                                TextField("URL or file path", text: Binding(
                                    get: { index < urls.count ? urls[index] : "" },
                                    set: { newValue in
                                        guard index < urls.count else { return }
                                        urls[index] = newValue
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Item \(index + 1) to open in \(app.displayName)")
                                .onSubmit(save)

                                Button {
                                    removeURL(at: index)
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove item \(index + 1)")
                            }
                        }
                    }
                }

                Toggle("Skip this app when restoring", isOn: $skip)
                    .accessibilityHint("Keeps \(app.displayName) pinned for switching but doesn't relaunch it")
            }
            .padding(.top, HopSpacing.xs)
            .padding(.leading, HopSpacing.sm)
            .onChange(of: priority) { save() }
            .onChange(of: delay) { save() }
            .onChange(of: skip) { save() }
            .onChange(of: urls) { save() }
        } label: {
            HStack(spacing: HopSpacing.sm) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 16, height: 16)
                    .accessibilityHidden(true)
                Text(app.displayName)
                    .font(.hopSubheading)
                    .lineLimit(1)
                Spacer(minLength: HopSpacing.sm)
                Text(summary)
                    .font(.hopCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .onAppear(perform: load)
    }

    private var summary: String {
        if skip { return "Skipped" }
        var parts: [String] = []
        parts.append(priority == 0 ? "order: last" : "order: \(priority)")
        if delay > 0 { parts.append(String(format: "+%.1fs", delay)) }
        if !urls.isEmpty { parts.append("\(urls.count) item\(urls.count == 1 ? "" : "s")") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Open with \(app.displayName)"
        panel.message = "Choose files or folders to open in \(app.displayName) when this profile's session is restored."
        guard panel.runModal() == .OK else { return }
        urls.append(contentsOf: panel.urls.map(\.path))
    }

    private func addURLPlaceholder() {
        urls.append("")
    }

    private func removeURL(at index: Int) {
        guard index < urls.count else { return }
        urls.remove(at: index)
    }

    private func load() {
        let options = appState.store.launchOptions(profileId: profileId, bundleId: app.bundleIdentifier)
        priority = options?.launchPriority ?? 0
        delay = options?.launchDelay ?? 0
        urls = options?.openURLs ?? []
        skip = options?.skipOnRestore ?? false
    }

    private func save() {
        let cleaned = urls
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let options = LaunchOptions(
            launchPriority: priority == 0 ? nil : priority,
            launchDelay: delay == 0 ? nil : delay,
            openURLs: cleaned.isEmpty ? nil : cleaned,
            skipOnRestore: skip ? true : nil
        )
        appState.store.setLaunchOptions(
            profileId: profileId,
            bundleId: app.bundleIdentifier,
            options: options.isEmpty ? nil : options
        )
    }
}

// MARK: - Profile Hotkey Row

struct ProfileHotkeyRow: View {
    @EnvironmentObject private var appState: AppState
    let profile: Profile

    @State private var shortcut: CustomShortcut?

    var body: some View {
        VStack(alignment: .leading, spacing: HopSpacing.xs) {
            LabeledContent {
                HStack(spacing: HopSpacing.sm) {
                    // Switcher-family binding: HotkeyService matches these WITHOUT
                    // Shift (Shift means "cycle backward"), so the recorder must
                    // strip it or the hotkey would never fire.
                    ShortcutRecorderView(shortcut: $shortcut, mode: .shiftInsensitive)
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
                }
            } label: {
                Label("Hotkey", systemImage: "keyboard")
            }

            if let conflict = hotkeyConflict {
                Label("Conflicts with \(conflict.message).", systemImage: "exclamationmark.triangle.fill")
                    .font(.hopCaption)
                    .foregroundStyle(HopColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            shortcut = profile.hotkey
        }
    }

    /// Uses the shared conflict engine, so this now also catches collisions with
    /// snap actions and with well-known macOS system shortcuts.
    private var hotkeyConflict: ShortcutConflict? {
        guard let hk = shortcut else { return nil }
        var externals: [NamedShortcut] = []
        let appSel = appState.appShortcutSelection
        externals.append(NamedShortcut(
            name: "the app switcher shortcut",
            shortcut: CustomShortcut(
                modifierFlagsRawValue: appSel.modifierFlags.rawValue,
                keyCode: appSel.keyCode
            )
        ))
        for other in appState.store.profiles where other.id != profile.id {
            if let hotkey = other.hotkey {
                externals.append(NamedShortcut(name: "the \(other.name) profile hotkey", shortcut: hotkey))
            }
        }
        return SnapShortcutConfig.current.conflict(for: hk, excluding: nil, against: externals)
    }
}

// MARK: - Window Rules Section

struct WindowRulesSection: View {
    var body: some View {
        Section {
            // Window Rules is not fully gated — the free tier gets 2 rules — so
            // the Pro view renders for everyone.
            if let provider = ProServiceRegistry.shared.provider,
               let view = provider.windowsSectionView() {
                view
            } else {
                ProLockedCard(
                    title: "Window Rules",
                    description: "\u{201C}Chrome \u{2192} Left Half on launch.\u{201D} Set a rule once and the app always opens where you want it. The free tier includes \(ProFeatureGate.freeWindowRuleLimit) rules.",
                    systemImage: "rectangle.badge.plus"
                )
            }
        } header: {
            Text("Window Rules")
        } footer: {
            Text("Set a rule like \"Chrome \u{2192} Left Half on launch\" and it will always open there. Great for keeping your workspace consistent without manually snapping every time.")
        }
    }
}

// MARK: - Displays Section

struct DisplaysSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if let provider = ProServiceRegistry.shared.provider, provider.isLicensed {
            Section {
                provider.displaysSectionView(
                    profiles: appState.store.profiles.map { ProProfileInfo(id: $0.id, name: $0.name) }
                )
            }
        } else {
            Section {
                ProLockedCard(
                    title: "Display Auto-Profiles",
                    description: "Plug in your external monitor and HopTab switches to your \u{201C}Docked\u{201D} profile; unplug and it switches back.",
                    systemImage: "display"
                )
            }
        }
    }
}


// MARK: - Browser profile picker

/// Chrome profiles come from Chrome's Local State; Safari profiles from its
/// File menu via Accessibility, so Safari must have run at least once with
/// profiles set up for them to appear.
private struct BrowserProfilePicker: View {
    @EnvironmentObject private var appState: AppState
    let profile: Profile

    @State private var options: [BrowserProfile] = []

    var body: some View {
        VStack(alignment: .leading, spacing: HopSpacing.xs) {
            Picker(selection: Binding(
                get: { profile.browserProfile?.key ?? "" },
                set: { key in
                    appState.store.setBrowserProfile(profileId: profile.id, options.first(where: { $0.key == key }))
                }
            )) {
                Text("None").tag("")
                ForEach(options, id: \.key) { option in
                    Text(option.displayName).tag(option.key)
                }
                if let current = profile.browserProfile, !options.contains(current) {
                    Text(current.displayName).tag(current.key)
                }
            } label: {
                Label("Browser profile", systemImage: "person.crop.rectangle")
                    .foregroundStyle(.secondary)
            }
            Text(footnote)
                .font(.hopFootnote)
                .foregroundStyle(.tertiary)
        }
        .task(id: profile.id) { await load() }
    }

    private var footnote: String {
        if options.isEmpty {
            return "No browser profiles found. Chrome profiles appear once Chrome has more than one; Safari profiles appear after Safari has run with profiles set up."
        }
        return "Switching to this workspace brings that profile\u{2019}s window to the front, opening one if needed."
    }

    private func load() async {
        let found: [BrowserProfile] = await Task.detached(priority: .userInitiated) {
            var out: [BrowserProfile] = []
            let chrome = ChromeDataService.profiles()
            if chrome.count > 1 {
                out += chrome.map { BrowserProfile.chrome(directory: $0.directory, name: $0.name) }
            }
            out += SafariProfilesService.profileNames().map { BrowserProfile.safari(name: $0) }
            return out
        }.value
        options = found
    }
}
