import AppKit
import SwiftUI

// MARK: - Panel metrics

private enum MenuPanel {
    /// Menu-bar popovers live in a narrow band; anything wider reads as a
    /// second Settings window.
    static let width: CGFloat = 320
    static let rowHeight: CGFloat = 44
    static let tile: CGFloat = 28
    static let glyph = CGSize(width: 20, height: 14)
}

// MARK: - Entry point

/// The menu-bar popover. `MenuBarExtra` is declared `.window` in `HopTabApp`,
/// so everything below is a real SwiftUI view with hover and keyboard
/// handling — not custom views smuggled into an `NSMenu`.
///
/// This wrapper exists only to bind the nested `PermissionsService`
/// `ObservableObject`; observing `AppState` alone never republishes when the
/// Accessibility grant flips.
struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MenuBarPanel(appState: appState, permissions: appState.permissions)
    }
}

// MARK: - Panel

/// The workspaces ARE the menu. Each row is one workspace with its apps,
/// state and hotkey; the active one is tinted. Snapping is a single quiet
/// row (it is a keyboard feature — the full picker lives in Settings), and
/// housekeeping is a line of text buttons.
private struct MenuBarPanel: View {
    @ObservedObject var appState: AppState
    @ObservedObject var permissions: PermissionsService
    @ObservedObject private var updateService = UpdateService.shared
    @State private var isPickingApps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let attention = currentAttention() {
                AttentionRow(attention: attention, appState: appState)
                Divider()
            }

            workspacesSection

            if let statusProvider = ProServiceRegistry.shared.provider as? ProMenuStatusProvider {
                // Re-read once a second while the panel is open so the timers
                // count down. Nothing runs when it is closed.
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let status = statusProvider.menuStatus, StatusSection.hasContent(status) {
                        Divider()
                        StatusSection(status: status, provider: statusProvider, appState: appState)
                    }
                }
            }

            Divider()
            snapRow

            Divider()
            footer
        }
        .frame(width: MenuPanel.width)
    }

    // MARK: Workspaces

    @ViewBuilder
    private var workspacesSection: some View {
        let profiles = appState.store.profiles
        let activeId = appState.store.activeProfileId
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Workspaces")
                Spacer(minLength: 0)
                Text("\(appState.profileShortcutModifierName) + \(appState.profileShortcutKeyName) switches")
                    .font(.hopFootnote)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, HopSpacing.sm)
            .padding(.bottom, HopSpacing.xs)

            if profiles.isEmpty {
                Text("No workspaces yet.")
                    .font(.hopSubheading)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, HopSpacing.sm)
                    .padding(.vertical, HopSpacing.xs)
            }

            ForEach(profiles) { candidate in
                WorkspaceRow(
                    profile: candidate,
                    isActive: candidate.id == activeId,
                    isSwitching: appState.isApplyingProfile && candidate.id == activeId,
                    hasDesktop: appState.store.spaceForProfile(candidate.id) != nil,
                    canRestore: appState.canRestoreSession(profileId: candidate.id),
                    activate: {
                        guard candidate.id != activeId else { return }
                        appState.activateProfile(id: candidate.id)
                    },
                    saveAndClose: { appState.saveAndCloseSession(profileId: candidate.id) },
                    restore: { appState.restoreSession(profileId: candidate.id) },
                    applyLayout: candidate.layoutBinding.map { !$0.zoneAssignments.isEmpty } == true
                        && candidate.id == activeId
                        ? { appState.applyLayoutForActiveProfile() } : nil,
                    edit: {
                        SettingsNavigation.shared.selectedWorkspaceId = candidate.id
                        SettingsNavigation.open(.workspaces)
                    },
                    delete: { appState.store.deleteProfile(id: candidate.id) }
                )
            }

            if isPickingApps {
                NewWorkspacePicker(
                    candidates: appState.runningAppCandidates(),
                    onCancel: { withAnimation(HopMotion.snappy) { isPickingApps = false } },
                    onCreate: { name, ids in
                        appState.createProfile(named: name, bundleIdentifiers: ids)
                        withAnimation(HopMotion.snappy) { isPickingApps = false }
                    }
                )
            } else {
                newWorkspaceButton
            }
        }
        .padding(.horizontal, HopSpacing.sm)
        .padding(.vertical, HopSpacing.sm)
        .onDisappear { isPickingApps = false }
    }

    @ViewBuilder
    private var newWorkspaceButton: some View {
        let canAdd = appState.store.canAddProfile
        Button {
            withAnimation(HopMotion.snappy) { isPickingApps = true }
        } label: {
            HStack(spacing: HopSpacing.sm) {
                Image(systemName: canAdd ? "plus" : "lock")
                    .font(.hopSubheading.weight(.medium))
                    .frame(width: MenuPanel.tile, height: MenuPanel.tile)
                    .background(
                        RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    )
                Text(canAdd ? "New workspace from what\u{2019}s open" : "More workspaces with Pro")
                    .font(.hopSubheading)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(canAdd ? Color.accentColor : Color.secondary)
            .padding(.horizontal, HopSpacing.sm)
            .frame(minHeight: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(tinted: false))
        .disabled(!canAdd)
        .help(canAdd
              ? "Pick which of the running apps the new workspace should hold."
              : "The free tier allows \(ProFeatureGate.freeProfileLimit) workspaces.")
        .accessibilityLabel(canAdd ? "New workspace from running apps" : "Workspace limit reached")
    }

    // MARK: Snap

    /// The everyday five. Everything else is one keystroke or Settings away.
    @ViewBuilder
    private var snapRow: some View {
        HStack(spacing: HopSpacing.xs) {
            SectionLabel("Snap")
            Text("\u{2303}\u{2325} arrows")
                .font(.hopFootnote)
                .foregroundStyle(.tertiary)
            Spacer(minLength: HopSpacing.sm)
            ForEach([SnapDirection.left, .right, .full, .center], id: \.self) { direction in
                SnapIconButton(direction: direction) { snap(direction) }
            }
            TextIconButton(systemImage: "arrow.uturn.backward", label: "Undo last move") {
                appState.performSnapAction(.undo)
            }
        }
        .padding(.horizontal, HopSpacing.md)
        .padding(.vertical, HopSpacing.sm)
    }

    /// Route a snap the same way the global hotkeys and `hoptab://` links do,
    /// so the panel and the keyboard can never drift apart.
    ///
    /// `LayoutService.snapFrontmost(to:)` targets `NSWorkspace.frontmostApplication`.
    /// A `.window` MenuBarExtra can make HopTab itself frontmost, which would
    /// aim every snap at a panel with no resizable window — so when that
    /// happens, fall back to the topmost window that is not ours.
    private func snap(_ direction: SnapDirection) {
        let selfID = Bundle.main.bundleIdentifier
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        if front != nil, front == selfID, let target = Self.topmostForeignApp()?.bundleIdentifier {
            LayoutService.snapApp(bundleIdentifier: target, to: direction)
        } else {
            appState.performSnapAction(direction)
        }
    }

    /// The owner of the frontmost normal (layer 0) window that isn't HopTab.
    /// Owner PID and layer need no Screen Recording grant — only titles do.
    private static func topmostForeignApp() -> NSRunningApplication? {
        let mine = ProcessInfo.processInfo.processIdentifier
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        for entry in list {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != mine,
                  let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular
            else { continue }
            return app
        }
        return nil
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: HopSpacing.sm) {
            TextButton(title: "Settings\u{2026}") {
                NSApp.sendAction(#selector(AppDelegate.openSettings(_:)), to: nil, from: nil)
            }
            .keyboardShortcut(",", modifiers: .command)

            Spacer(minLength: 0)

            if let update = updateService.availableUpdate {
                TextButton(title: "Update to \(update.version)", prominent: true) {
                    updateService.downloadUpdate(update)
                }
            } else {
                TextButton(title: updateService.isChecking ? "Checking\u{2026}" : "Check for Updates") {
                    Task { await updateService.checkForUpdates() }
                }
                .disabled(updateService.isChecking)
            }

            TextButton(title: "Quit") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .padding(.horizontal, HopSpacing.md)
        .padding(.vertical, HopSpacing.sm)
    }

    // MARK: Attention

    /// One quiet row, highest severity first — not four stacked banners.
    private func currentAttention() -> Attention? {
        if !permissions.isTrusted { return .accessibility }
        if appState.isSecureInputActive { return .secureInput }
        if appState.hotkeyStatus == .failed { return .hotkeyFailed }
        if let update = updateService.availableUpdate { return .update(update.version) }
        return nil
    }
}

// MARK: - Workspace row

/// Icon tile · name + one-line state · app icons · hotkey · ⋯ on hover.
private struct WorkspaceRow: View {
    let profile: Profile
    let isActive: Bool
    let isSwitching: Bool
    let hasDesktop: Bool
    let canRestore: Bool
    let activate: () -> Void
    let saveAndClose: () -> Void
    let restore: () -> Void
    let applyLayout: (() -> Void)?
    let edit: () -> Void
    let delete: () -> Void

    @State private var hovering = false
    @State private var confirmingDelete = false

    var body: some View {
        let running = profile.pinnedApps.filter(\.isRunning).count
        Button(action: activate) {
            HStack(spacing: HopSpacing.sm) {
                WorkspaceTile(apps: profile.pinnedApps, isActive: isActive)

                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.name)
                        .font(.hopSubheading.weight(isActive ? .semibold : .medium))
                        .lineLimit(1)
                    Text(subtitle(running: running))
                        .font(.hopFootnote)
                        .foregroundStyle(isActive ? Color.accentColor.opacity(0.9) : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: HopSpacing.xs)

                if isSwitching {
                    ProgressView().controlSize(.mini)
                } else if hovering {
                    rowMenu
                } else if let hotkey = profile.hotkey {
                    Text(hotkey.displayName)
                        .font(.hopFootnote.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, HopSpacing.sm)
            .frame(minHeight: MenuPanel.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(tinted: isActive))
        .onHover { inside in
            withAnimation(HopMotion.snappy) { hovering = inside }
        }
        .accessibilityLabel(isActive ? "\(profile.name), current workspace" : "Switch to \(profile.name)")
        .accessibilityAddTraits(isActive ? .isSelected : [])
    }

    private func subtitle(running: Int) -> String {
        var parts: [String] = []
        if isActive {
            parts.append("Active")
        }
        let total = profile.pinnedApps.count
        parts.append(total == 1 ? "1 app" : "\(total) apps")
        if running > 0 && running != total { parts.append("\(running) running") }
        if let browser = profile.browserProfile { parts.append(browser.profileName) }
        else if hasDesktop { parts.append("own desktop") }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var rowMenu: some View {
        Menu {
            Button("Save & Close Windows", action: saveAndClose)
                .disabled(!SessionSnapshotService.hasRunningApps(profile))
            Button("Restore Windows", action: restore)
                .disabled(!canRestore)
            if let applyLayout {
                Button("Apply Layout", action: applyLayout)
            }
            Divider()
            Button("Edit in Settings\u{2026}", action: edit)
            Button("Delete Workspace\u{2026}", role: .destructive) { confirmingDelete = true }
        } label: {
            Image(systemName: "ellipsis")
                .font(.hopSubheading.weight(.semibold))
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .accessibilityLabel("\(profile.name) actions")
        .confirmationDialog(
            "Delete \u{201C}\(profile.name)\u{201D}?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Workspace", role: .destructive, action: delete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The apps stay installed. Only the workspace and its shortcut are removed.")
        }
    }
}

/// Up to four app icons in a 2×2 tile; one app gets the full tile.
private struct WorkspaceTile: View {
    let apps: [PinnedApp]
    let isActive: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
        ZStack {
            shape.fill(Color.primary.opacity(isActive ? 0.0 : 0.06))
            if apps.isEmpty {
                Image(systemName: "square.dashed")
                    .foregroundStyle(.tertiary)
            } else if apps.count == 1 {
                Image(nsImage: apps[0].icon)
                    .resizable()
                    .frame(width: 22, height: 22)
            } else {
                let shown = Array(apps.prefix(4))
                Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                    GridRow {
                        miniIcon(shown, 0); miniIcon(shown, 1)
                    }
                    GridRow {
                        miniIcon(shown, 2); miniIcon(shown, 3)
                    }
                }
            }
        }
        .frame(width: MenuPanel.tile, height: MenuPanel.tile)
        .overlay(shape.strokeBorder(isActive ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1))
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func miniIcon(_ apps: [PinnedApp], _ index: Int) -> some View {
        if index < apps.count {
            Image(nsImage: apps[index].icon)
                .resizable()
                .frame(width: 11, height: 11)
        } else {
            Color.clear.frame(width: 11, height: 11)
        }
    }
}


// MARK: - Attention row

private enum Attention: Equatable {
    case accessibility
    case secureInput
    case hotkeyFailed
    case update(String)
}

private struct AttentionRow: View {
    let attention: Attention
    let appState: AppState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HopSpacing.sm) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(message)
                .font(.hopSubheading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle {
                // Bordered, not prominent: prominent paints white text on the
                // warning yellow, which is unreadable in dark mode.
                Button(actionTitle, action: performAction)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .tint(tint)
                    .fontWeight(.semibold)
            }
        }
        .padding(.horizontal, HopSpacing.md)
        .padding(.vertical, HopSpacing.sm)
        .background(HopColor.tint(tint))
    }

    private var tint: Color {
        switch attention {
        case .accessibility, .secureInput, .hotkeyFailed: return HopColor.warning
        case .update: return .accentColor
        }
    }

    private var icon: String {
        switch attention {
        case .accessibility: return "exclamationmark.shield"
        case .secureInput: return "lock.shield"
        case .hotkeyFailed: return "keyboard.badge.ellipsis"
        case .update: return "arrow.down.circle"
        }
    }

    private var message: String {
        switch attention {
        case .accessibility:
            return "HopTab needs Accessibility permission to move and switch windows."
        case .secureInput:
            return "Shortcuts paused: a password field has keyboard security on."
        case .hotkeyFailed:
            return "Shortcuts aren't running. macOS may have disabled the event tap."
        case .update(let version):
            return "Version \(version) is available."
        }
    }

    private var actionTitle: String? {
        switch attention {
        case .accessibility: return "Grant"
        case .secureInput: return nil
        case .hotkeyFailed: return "Retry"
        case .update: return "Download"
        }
    }

    private func performAction() {
        switch attention {
        case .accessibility:
            // Falls back to opening System Settings once macOS has spent its
            // one-time dialog, so the button is never a dead end.
            appState.permissions.requestAccessibility()
        case .secureInput:
            break
        case .hotkeyFailed:
            appState.retryHotkey()
        case .update:
            if let update = UpdateService.shared.availableUpdate {
                UpdateService.shared.downloadUpdate(update)
            }
        }
    }
}

// MARK: - New workspace picker

/// Inline: the running apps as checkable rows (all on to start), a name,
/// Create. Replaces the "New workspace" row while open.
private struct NewWorkspacePicker: View {
    let candidates: [NSRunningApplication]
    let onCancel: () -> Void
    let onCreate: (String, [String]) -> Void

    @State private var name = ""
    @State private var selected: Set<String> = []
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: HopSpacing.xs) {
            TextField("Workspace name", text: $name)
                .textFieldStyle(.plain)
                .font(.hopSubheading.weight(.medium))
                .padding(.horizontal, HopSpacing.sm)
                .frame(height: 30)
                .background(
                    RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                )
                .focused($nameFocused)
                .onSubmit(create)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(candidates, id: \.processIdentifier) { app in
                        if let id = app.bundleIdentifier {
                            appRow(app, id: id)
                        }
                    }
                }
            }
            .frame(height: CGFloat(min(max(candidateIds.count, 1), 7)) * 30)

            HStack {
                Text(selected.isEmpty ? "Tick the apps to include" : "\(selected.count) of \(candidateIds.count) apps")
                    .font(.hopFootnote)
                    .foregroundStyle(.secondary)
                Spacer()
                TextButton(title: selected.count == candidateIds.count ? "Clear" : "All") {
                    selected = selected.count == candidateIds.count ? [] : Set(candidateIds)
                }
                TextButton(title: "Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                TextButton(title: "Create", prominent: true, action: create)
                    .disabled(selected.isEmpty)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, HopSpacing.sm)
        .padding(.vertical, HopSpacing.xs)
        .onAppear { nameFocused = true }
    }

    private var candidateIds: [String] { candidates.compactMap(\.bundleIdentifier) }

    private func appRow(_ app: NSRunningApplication, id: String) -> some View {
        let on = selected.contains(id)
        return Button {
            if on { selected.remove(id) } else { selected.insert(id) }
        } label: {
            HStack(spacing: HopSpacing.sm) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.hopSubheading)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary.opacity(0.6))
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                }
                Text(app.localizedName ?? id)
                    .font(.hopSubheading)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HopSpacing.sm)
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(tinted: false))
        .accessibilityLabel(app.localizedName ?? id)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func create() {
        guard !selected.isEmpty else { return }
        // Keep the candidates' recency order.
        let ids = candidates.compactMap(\.bundleIdentifier).filter { selected.contains($0) }
        onCreate(name, ids)
    }
}

// MARK: - Now (Pro)

/// What is happening right now: a meeting, a running timer, the next break,
/// and today's tracked time. Each line is one row with at most one action.
private struct StatusSection: View {
    let status: ProMenuStatus
    let provider: ProMenuStatusProvider
    let appState: AppState

    static func hasContent(_ s: ProMenuStatus) -> Bool {
        s.meeting != nil || s.focusSessionSecondsRemaining != nil || s.pomodoro != nil
            || s.screenBreaksEnabled || s.trackedTodaySeconds >= 60
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel("Now")
                .padding(.horizontal, HopSpacing.sm)
                .padding(.bottom, HopSpacing.xs)

            if let meeting = status.meeting {
                meetingRow(meeting)
            }
            if let pomodoro = status.pomodoro {
                StatusRow(
                    icon: pomodoro.isBreak ? "cup.and.saucer" : "timer",
                    tint: pomodoro.isBreak ? HopColor.success : .accentColor,
                    title: "\(pomodoro.phaseLabel) \u{00B7} \(pomodoro.eventTitle)",
                    detail: "\(Self.clock(pomodoro.secondsRemaining)) left \u{00B7} interval \(pomodoro.completedIntervals + 1)",
                    actionTitle: pomodoro.isBreak ? "Skip" : "Stop"
                ) {
                    if pomodoro.isBreak { ProServiceRegistry.shared.provider?.skipPomodoroBreak() }
                    else { ProServiceRegistry.shared.provider?.stopPomodoro() }
                }
            } else if let remaining = status.focusSessionSecondsRemaining {
                StatusRow(
                    icon: "moon.zzz",
                    tint: .accentColor,
                    title: "Focus session" + (status.focusSessionProfileName.map { " \u{00B7} \($0)" } ?? ""),
                    detail: "\(Self.clock(remaining)) left",
                    actionTitle: "End"
                ) { ProServiceRegistry.shared.provider?.stopFocusSession() }
            }
            if status.screenBreaksEnabled {
                if status.isOnBreak {
                    StatusRow(icon: "cup.and.saucer.fill", tint: HopColor.success,
                              title: "On a break", detail: "Esc on the break screen skips it",
                              actionTitle: "Skip") { provider.skipBreak() }
                } else if let seconds = status.secondsUntilNextBreak {
                    StatusRow(icon: "cup.and.saucer", tint: .secondary,
                              title: "Next break in \(Self.clock(seconds))",
                              detail: "Screen breaks on",
                              actionTitle: "Break now") { provider.takeBreakNow() }
                } else {
                    StatusRow(icon: "cup.and.saucer", tint: .secondary,
                              title: "Break clock paused",
                              detail: "Resumes when you are back at the keyboard",
                              actionTitle: nil) {}
                }
            }
            if status.trackedTodaySeconds >= 60 {
                let top = status.topWorkspaceToday
                StatusRow(
                    icon: "chart.bar",
                    tint: .secondary,
                    title: "\(Self.hours(status.trackedTodaySeconds)) today",
                    detail: top.map { "Most in \($0.name) \u{00B7} \(Self.hours($0.seconds))" } ?? "Across all workspaces",
                    actionTitle: "Details"
                ) { SettingsNavigation.open(.tracking) }
            }
        }
        .padding(.horizontal, HopSpacing.sm)
        .padding(.vertical, HopSpacing.sm)
    }

    private func meetingRow(_ meeting: ProMenuStatus.Meeting) -> some View {
        let live = meeting.start == nil
        let detail: String = {
            guard let start = meeting.start else { return "In progress" }
            let minutes = max(0, Int(ceil(start.timeIntervalSinceNow / 60)))
            if minutes == 0 { return "Starting now" }
            if minutes < 60 { return "In \(minutes) min" }
            return "At " + start.formatted(date: .omitted, time: .shortened)
        }()
        return StatusRow(
            icon: live ? "record.circle" : "calendar.badge.clock",
            tint: live ? HopColor.success : .secondary,
            title: meeting.title,
            detail: detail,
            actionTitle: meeting.url == nil ? nil : (live ? "Join" : "Join early")
        ) {
            if let url = meeting.url { NSWorkspace.shared.open(url) }
        }
    }

    static func clock(_ seconds: Int) -> String {
        let m = seconds / 60, s = seconds % 60
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : String(format: "%d:%02d", m, s)
    }

    static func hours(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let m = minutes % 60
        return m > 0 ? "\(minutes / 60)h \(m)m" : "\(minutes / 60)h"
    }
}

private struct StatusRow: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let actionTitle: String?
    let action: () -> Void

    var body: some View {
        HStack(spacing: HopSpacing.sm) {
            Image(systemName: icon)
                .font(.hopSubheading)
                .foregroundStyle(tint)
                .frame(width: MenuPanel.tile, height: MenuPanel.tile)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.hopSubheading.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.hopFootnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: HopSpacing.xs)
            if let actionTitle {
                TextButton(title: actionTitle, action: action)
            }
        }
        .padding(.horizontal, HopSpacing.sm)
        .frame(minHeight: 36)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Snap glyph

private struct SnapGlyph: View {
    let direction: SnapDirection
    var isActive: Bool = false

    private var fractions: (x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat) {
        switch direction {
        // Frame-relative: no screen fraction exists. Draw the intent instead.
        case .maximizeHeight: return (0.3, 0, 0.4, 1)
        // 92% of the screen is visually identical to 100% at this size;
        // exaggerate the inset so it can be told apart from Maximize.
        case .almostMaximize: return (0.14, 0.14, 0.72, 0.72)
        default: return direction.fractions
        }
    }

    var body: some View {
        let size = MenuPanel.glyph
        let f = fractions
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Color.accentColor.opacity(isActive ? 1 : 0.8))
                .frame(
                    width: max(2, size.width * f.w - 2),
                    height: max(2, size.height * f.h - 2)
                )
                .offset(x: size.width * f.x + 1, y: size.height * f.y + 1)
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }
}

// MARK: - Shared controls

private struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text.uppercased())
            .font(.hopFootnote.weight(.semibold))
            .kerning(0.4)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct SnapIconButton: View {
    let direction: SnapDirection
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            SnapGlyph(direction: direction, isActive: hovering)
                .frame(width: 30, height: 24)
        }
        .buttonStyle(RowButtonStyle(tinted: false))
        .onHover { inside in
            withAnimation(HopMotion.snappy) { hovering = inside }
        }
        .help("Snap \(direction.displayName)")
        .accessibilityLabel("Snap \(direction.displayName)")
    }
}

private struct TextIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.hopSubheading)
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 24)
        }
        .buttonStyle(RowButtonStyle(tinted: false))
        .onHover { inside in
            withAnimation(HopMotion.snappy) { hovering = inside }
        }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Footer action: text only, a soft fill on hover. Not boxed.
private struct TextButton: View {
    let title: String
    var prominent: Bool = false
    let action: () -> Void

    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.hopSubheading.weight(prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Color.accentColor : (hovering ? Color.primary : Color.secondary))
                .lineLimit(1)
                .padding(.horizontal, HopSpacing.sm)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle(tinted: false))
        .onHover { inside in
            withAnimation(HopMotion.snappy) { hovering = inside }
        }
        .opacity(isEnabled ? 1 : 0.5)
        .accessibilityLabel(title)
    }
}

/// Row chrome: a soft fill on hover/press, an accent tint for the active
/// workspace, no stroke anywhere.
private struct RowButtonStyle: ButtonStyle {
    let tinted: Bool
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: HopRadius.card - 2, style: .continuous)
        return configuration.label
            .foregroundStyle(.primary)
            .background(
                shape.fill(tinted
                           ? Color.accentColor.opacity(configuration.isPressed ? 0.22 : (hovering ? 0.18 : 0.14))
                           : Color.primary.opacity(configuration.isPressed ? 0.12 : (hovering ? 0.07 : 0)))
            )
            .contentShape(shape)
            .onHover { inside in
                withAnimation(HopMotion.snappy) { hovering = inside }
            }
    }
}


// MARK: - Secure input

/// macOS secure event input (Terminal's Secure Keyboard Entry, a focused
/// password field) starves the event tap, so every global shortcut stops
/// firing with no visible explanation.
///
/// `HotkeyService` tracks this, but `AppState` keeps that service private and
/// republishes nothing, so the panel reads the flag itself — only while it is
/// on screen, so nothing polls in the background.
