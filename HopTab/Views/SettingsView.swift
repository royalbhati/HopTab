import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Sidebar Navigation

/// The Settings sidebar sections, in display order.
///
/// Deliberately `internal` (not `private`) so other surfaces can deep-link into
/// a specific section — see `SettingsNavigation.open(_:)`. The old behaviour
/// ("open Settings to whatever was last shown") made the "I have a key"
/// affordance in the layout picker land on an arbitrary pane.
enum HopSettingsSection: String, CaseIterable, Identifiable {
    case workspaces = "Workspaces"
    case shortcuts = "Shortcuts"
    case palette = "Command Palette"
    case calendar = "Calendar"
    case tracking = "Time Tracking"
    case breaks = "Screen Breaks"
    case pro = "Automation"
    case general = "General"

    var id: String { rawValue }
    var title: String { rawValue }

    /// Symbols chosen to actually signal the section's content.
    var icon: String {
        switch self {
        case .workspaces: return "square.stack.3d.up"
        case .shortcuts:  return "keyboard"
        case .palette:    return "command"
        case .calendar:   return "calendar"
        case .tracking:   return "chart.bar.xaxis"
        case .breaks:     return "cup.and.saucer"
        case .pro:        return "clock.arrow.2.circlepath"
        case .general:    return "gearshape"
        }
    }

    /// One line under the sidebar title, so the sidebar still tells you
    /// where things went.
    var subtitle: String {
        switch self {
        case .workspaces: return "Apps, layout, hotkey, desktop"
        case .shortcuts:  return "Switcher, snapping, gaps"
        case .palette:    return "\u{2325}K and your own commands"
        case .calendar:   return "Meetings switch workspaces"
        case .tracking:   return "Where your hours go"
        case .breaks:     return "Rest reminders that restore"
        case .pro:        return "Schedule, Focus, displays, rules"
        case .general:    return "Startup, permissions, updates"
        }
    }

    /// Name used in `hoptab://settings/<name>` deep links.
    var deepLinkName: String {
        switch self {
        case .workspaces: return "workspaces"
        case .shortcuts:  return "shortcuts"
        case .palette:    return "palette"
        case .calendar:   return "calendar"
        case .tracking:   return "tracking"
        case .breaks:     return "breaks"
        case .pro:        return "automation"
        case .general:    return "general"
        }
    }

    /// Sections whose feature is included with Pro. Shown with a small mark
    /// in the sidebar until a license is active.
    var isPro: Bool {
        switch self {
        case .calendar, .tracking, .breaks, .pro: return true
        case .workspaces, .shortcuts, .palette, .general: return false
        }
    }
}

/// Shared navigation state for the Settings window.
///
/// A singleton because the window is created once and reused; a deep link has
/// to be able to move the selection of an already-open window.
@MainActor
final class SettingsNavigation: ObservableObject {
    static let shared = SettingsNavigation()

    @Published var section: HopSettingsSection? = .workspaces
    @Published var searchQuery: String = ""
    /// Set when arriving via a deep link, so the target can highlight itself.
    @Published var focusedDestination: HopSettingsSection?
    /// The workspace the Workspaces pane is editing. nil = the active one.
    @Published var selectedWorkspaceId: UUID?
    /// A palette query the user asked to save as a command (⌘N). The
    /// Command Palette pane consumes it by opening the editor prefilled.
    @Published var pendingCommandDraft: String?

    private init() {}

    /// Open (or raise) Settings at a specific section from anywhere in the app.
    ///
    /// Example — the layout picker's "I have a key" button:
    ///
    ///     SettingsNavigation.open(.pro)
    static func open(_ section: HopSettingsSection) {
        shared.section = section
        shared.searchQuery = ""
        shared.focusedDestination = section
        NSApp.sendAction(#selector(AppDelegate.openSettings(_:)), to: nil, from: nil)
    }
}

// MARK: - Settings Window Controller

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?

    func show(appState: AppState, destination: HopSettingsSection? = nil) {
        // The installed-app list is scanned lazily, off the main thread, the
        // first time Settings opens — it used to cost 0.3-1.5s of every launch
        // for a picker most users open once. Safe to call repeatedly.
        appState.ensureInstalledAppsLoaded()

        if let destination {
            SettingsNavigation.shared.section = destination
            SettingsNavigation.shared.focusedDestination = destination
        }

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
        w.contentMinSize = NSSize(width: 860, height: 560)
        w.setContentSize(NSSize(width: 1040, height: 720))
        w.setFrameAutosaveName("HopTabSettings.v2")
        if w.frame.width < 860 { w.setContentSize(NSSize(width: 1040, height: 720)); w.center() }
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }
}

// MARK: - Search Index

/// One searchable control. The index is hand-maintained (there is no way to
/// introspect a SwiftUI `Form`), which is why every entry names the section it
/// lives in rather than trying to scroll to a row.
struct SettingsSearchEntry: Identifiable {
    let id: String
    let section: HopSettingsSection
    let title: String
    let keywords: String

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        let haystack = "\(title) \(keywords)".lowercased()
        if haystack.contains(q.lowercased()) { return true }
        return fuzzyMatch(query: q, target: title)
    }
}

enum SettingsSearch {
    static let entries: [SettingsSearchEntry] = [
        .init(id: "launch-at-login", section: .general, title: "Launch at login",
              keywords: "startup start login item open automatically boot"),
        .init(id: "accessibility", section: .general, title: "Accessibility permission",
              keywords: "permission trusted grant access privacy security ax"),
        .init(id: "secure-input", section: .general, title: "Secure input",
              keywords: "password field shortcuts paused keyboard security"),
        .init(id: "recent-first", section: .general, title: "Move recently switched app to front",
              keywords: "mru order switcher behavior recent"),
        .init(id: "sip", section: .general, title: "Advanced space control",
              keywords: "sip system integrity protection desktop space yabai"),

        .init(id: "app-switcher", section: .shortcuts, title: "App switcher shortcut",
              keywords: "option tab control command backtick cycle hotkey"),
        .init(id: "profile-switcher", section: .shortcuts, title: "Profile switcher shortcut",
              keywords: "profile hotkey switch cycle"),
        .init(id: "hotkey-status", section: .shortcuts, title: "Shortcut status",
              keywords: "hotkey failed retry event tap accessibility"),
        .init(id: "quick-reference", section: .shortcuts, title: "Quick reference",
              keywords: "cheatsheet keys help shortcuts list"),

        .init(id: "drag-snap", section: .shortcuts, title: "Drag to snap",
              keywords: "edge corner drag mouse snap zones"),
        .init(id: "restore-unsnap", section: .shortcuts, title: "Restore size when dragging away",
              keywords: "unsnap restore original size drag"),
        .init(id: "disable-modifier", section: .shortcuts, title: "Hold to move without snapping",
              keywords: "modifier control option command shift disable escape hatch"),
        .init(id: "bottom-thirds", section: .shortcuts, title: "Bottom edge thirds",
              keywords: "bottom half thirds drag edge split"),
        .init(id: "system-tiling", section: .shortcuts, title: "macOS window tiling conflict",
              keywords: "sequoia native tiling desktop dock edge drag conflict"),
        .init(id: "gaps", section: .shortcuts, title: "Window gaps",
              keywords: "gap padding spacing margin inner outer edge"),
        .init(id: "snap-shortcuts", section: .shortcuts, title: "Snap shortcuts",
              keywords: "halves quarters thirds sixths ninths maximize center move edge undo redo cycle"),
        .init(id: "snap-import", section: .shortcuts, title: "Import / export shortcuts",
              keywords: "backup json migrate rectangle magnet transfer"),
        .init(id: "snap-defaults", section: .shortcuts, title: "Add new default shortcuts",
              keywords: "defaults missing upgrade merge reset"),

        .init(id: "custom-commands", section: .palette, title: "Custom commands",
              keywords: "palette command link url file shortcut keystroke shell script paste snippet raycast alfred"),
        .init(id: "commands-import", section: .palette, title: "Import / export commands",
              keywords: "json share pack backup commands"),

        .init(id: "layout-templates", section: .workspaces, title: "Layout templates",
              keywords: "zones grid template custom layout apply"),

        .init(id: "pinned-apps", section: .workspaces, title: "Pinned apps",
              keywords: "pin app list order display assignment"),
        .init(id: "profiles", section: .workspaces, title: "Profiles",
              keywords: "profile workspace create rename delete hotkey sticky note"),
        .init(id: "launch-order", section: .workspaces, title: "Launch order",
              keywords: "restore session priority delay open url skip"),
        .init(id: "session", section: .workspaces, title: "Save & restore session",
              keywords: "session snapshot quit reopen restore"),

        .init(id: "window-rules", section: .pro, title: "Window rules",
              keywords: "rule app snap on launch focus automatic"),
        .init(id: "calendar", section: .calendar, title: "Calendar auto-switch",
              keywords: "meeting zoom teams meet event profile"),
        .init(id: "meeting-mode", section: .calendar, title: "Meeting Mode",
              keywords: "meeting join link browser remind before restore after companion apps"),
        .init(id: "event-overrides", section: .calendar, title: "Event overrides",
              keywords: "override event rule assign profile reminder apps links"),
        .init(id: "schedule", section: .pro, title: "Time schedule",
              keywords: "schedule time of day weekday switch"),
        .init(id: "focus-mode", section: .pro, title: "Focus mode integration",
              keywords: "focus do not disturb mapping profile"),
        .init(id: "displays", section: .pro, title: "Display auto-profiles",
              keywords: "monitor external docked undock display profile"),
        .init(id: "time-tracking", section: .tracking, title: "Time tracking",
              keywords: "time spent profile stats usage hours week chart"),
        .init(id: "app-budgets", section: .tracking, title: "Per-app budgets",
              keywords: "budget limit daily app usage nudge"),
        .init(id: "pomodoro", section: .calendar, title: "Pomodoro",
              keywords: "pomodoro timer interval focus work break event"),
        .init(id: "focus-session", section: .tracking, title: "Focus sessions",
              keywords: "focus session minutes allowed apps nudge"),

        .init(id: "screen-breaks", section: .breaks, title: "Screen breaks",
              keywords: "break rest eyes reminder pause interval 20-20-20"),
        .init(id: "break-now", section: .breaks, title: "Take a break now",
              keywords: "break now start manual"),

        .init(id: "license", section: .pro, title: "License key",
              keywords: "license key activate unlock pro purchase i have a key"),
        .init(id: "pro-features", section: .pro, title: "Pro features",
              keywords: "pro paid upgrade unlock five dollars"),
        .init(id: "window-undo", section: .shortcuts, title: "Window undo",
              keywords: "undo redo window move resize history"),
        .init(id: "labs", section: .pro, title: "Labs — experimental",
              keywords: "labs experimental beta bsp tiling auto-tiling yabai"),

        .init(id: "updates", section: .general, title: "Check for updates",
              keywords: "update version download release"),
        .init(id: "onboarding", section: .general, title: "Show onboarding",
              keywords: "onboarding tutorial welcome intro"),
        .init(id: "version", section: .general, title: "Version",
              keywords: "about version build credits"),
    ]

    static func matches(_ query: String) -> [SettingsSearchEntry] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        return entries.filter { $0.matches(q) }
    }
}

// MARK: - Settings Root View

struct SettingsRootView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var nav = SettingsNavigation.shared

    private var results: [SettingsSearchEntry] { SettingsSearch.matches(nav.searchQuery) }
    private var isSearching: Bool {
        !nav.searchQuery.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        } detail: {
            Form {
                if isSearching { searchSummary }
                contentView
            }
            .formStyle(.grouped)
            .navigationTitle(nav.section?.title ?? "Settings")
        }
        .frame(minWidth: 860, minHeight: 540)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            if isSearching {
                searchResultsList
            } else {
                List(HopSettingsSection.allCases, selection: $nav.section) { section in
                    Label {
                        HStack(alignment: .firstTextBaseline, spacing: HopSpacing.xs) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(section.title)
                                Text(section.subtitle)
                                    .font(.hopFootnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            if section.isPro && !ProServiceRegistry.shared.isLicensed {
                                Text("PRO")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(HopColor.pro)
                                    .accessibilityLabel("Pro feature")
                            }
                        }
                    } icon: {
                        Image(systemName: section.icon)
                    }
                    .padding(.vertical, 3)
                    .tag(section)
                }
                .listStyle(.sidebar)
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: HopSpacing.xs) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search settings", text: $nav.searchQuery)
                .textFieldStyle(.plain)
                .accessibilityLabel("Search settings")
            if isSearching {
                Button {
                    nav.searchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, HopSpacing.sm)
        .padding(.vertical, HopSpacing.sm)
    }

    private var searchResultsList: some View {
        List {
            if results.isEmpty {
                VStack(alignment: .leading, spacing: HopSpacing.xs) {
                    Text("No matches")
                        .font(.hopSubheading)
                    Text("Try \u{201C}gap\u{201D}, \u{201C}hotkey\u{201D}, or \u{201C}license\u{201D}.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, HopSpacing.xs)
            } else {
                ForEach(HopSettingsSection.allCases) { section in
                    let inSection = results.filter { $0.section == section }
                    if !inSection.isEmpty {
                        Section(section.title) {
                            ForEach(inSection) { entry in
                                Button {
                                    nav.section = section
                                } label: {
                                    HStack(spacing: HopSpacing.sm) {
                                        Image(systemName: section.icon)
                                            .foregroundStyle(.secondary)
                                            .frame(width: 16)
                                            .accessibilityHidden(true)
                                        Text(entry.title)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 0)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(entry.title), in \(section.title)")
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Detail

    @ViewBuilder
    private var searchSummary: some View {
        let here = results.filter { $0.section == (nav.section ?? .workspaces) }
        Section {
            VStack(alignment: .leading, spacing: HopSpacing.xs) {
                if here.isEmpty {
                    Text("No matches for \u{201C}\(nav.searchQuery)\u{201D} in \(nav.section?.title ?? "this section").")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                    if let first = results.first {
                        Button("Go to \(first.section.title)") { nav.section = first.section }
                            .controlSize(.small)
                    }
                } else {
                    Text("\(here.count) match\(here.count == 1 ? "" : "es") for \u{201C}\(nav.searchQuery)\u{201D} here:")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                    ForEach(here) { entry in
                        Label(entry.title, systemImage: "arrow.turn.down.right")
                            .font(.hopCaption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch nav.section ?? .workspaces {
        case .workspaces:
            WorkspacesPane()
        case .shortcuts:
            ShortcutsSection()
            SnappingSection()
            WindowActionsSection()
        case .palette:
            CommandPalettePane(store: appState.customCommands)
        case .calendar:
            CalendarPane()
        case .tracking:
            TrackingPane()
        case .breaks:
            ScreenBreaksPane()
        case .pro:
            if !ProServiceRegistry.shared.isLicensed {
                ProSection()
            }
            AutomationPane()
            WindowRulesSection()
            DisplaysSection()
            ProLabsGroup(placement: nil)
            if ProServiceRegistry.shared.isLicensed {
                ProLicenseSection()
            }
        case .general:
            GeneralSection()
            PermissionsSection()
            SwitcherBehaviorSection()
            AdvancedSpaceControlSection()
            AboutSection()
        }
    }
}

// MARK: - Fuzzy Match Helper

func fuzzyMatch(query: String, target: String) -> Bool {
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

// MARK: - Notification

extension Notification.Name {
    static let snapShortcutsChanged = Notification.Name("snapShortcutsChanged")
}
