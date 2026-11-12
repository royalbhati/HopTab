import AppKit
import Combine

/// Builds and caches the rows the ⌥K palette searches.
///
/// Cheap sources (workspaces, apps, HopTab actions) are rebuilt on the main
/// thread every time the palette opens. Chrome sources are read off-main:
/// open tabs on every open (they change constantly, and the Apple Event
/// round-trip is ~100 ms), bookmarks and history on a two-minute cache.
@MainActor
final class CommandPaletteIndex: ObservableObject {
    @Published private(set) var items: [CommandPaletteItem] = []
    /// True while a background read is outstanding, so the view can show
    /// that more rows may still arrive.
    @Published private(set) var isLoadingChrome = false

    private var baseItems: [CommandPaletteItem] = []
    private var tabItems: [CommandPaletteItem] = []
    private var bookmarkItems: [CommandPaletteItem] = []
    private var historyItems: [CommandPaletteItem] = []
    private var projectItems: [CommandPaletteItem] = []
    private var safariProfileItems: [CommandPaletteItem] = []
    private var windowItems: [CommandPaletteItem] = []
    private var tabItemsOfFrontApp: [CommandPaletteItem] = []
    private var chromeCacheDate: Date?
    private var generation = 0

    private static let chromeCacheLifetime: TimeInterval = 120

    /// Snap actions worth a row. Everything else stays behind its shortcut.
    private static let snapActions: [SnapDirection] = [
        .left, .right, .full, .center, .topHalf, .bottomHalf,
        .topLeft, .topRight, .bottomLeft, .bottomRight,
        .firstThird, .centerThird, .lastThird, .nextMonitor, .previousMonitor, .undo,
    ]

    struct Context {
        var profiles: [Profile]
        var activeProfileId: UUID?
        var installedApps: [InstalledAppsService.AppInfo]
        var runningApps: [NSRunningApplication]
        /// Bundle identifiers, most recently activated first.
        var recentOrder: [String]
        var canAddWorkspace: Bool
        var includeChrome: Bool
        var includeEditors: Bool = true
        /// The app that had focus when ⌥K was pressed; its windows get rows.
        var frontmostApp: NSRunningApplication?
        var customCommands: [CustomCommand] = []
    }

    /// Rebuild cheap rows now, kick off Chrome reads, publish as they land.
    func refresh(with context: Context) {
        generation += 1
        let gen = generation
        baseItems = Self.buildBase(context)
        windowItems = []
        tabItemsOfFrontApp = []
        publish()

        if let front = context.frontmostApp, let bundleId = front.bundleIdentifier,
           bundleId != Bundle.main.bundleIdentifier {
            let icon: CommandPaletteItem.Icon = front.bundleURL
                .map { .image(InstalledAppsService.icon(forPath: $0.path)) } ?? .symbol("macwindow")
            let appName = front.localizedName ?? bundleId
            AppSwitcherService.enumerateNativeTabs(of: front) { [weak self] tabs in
                guard let self, self.generation == gen else { return }
                self.tabItemsOfFrontApp = tabs.enumerated().compactMap { i, t in
                    CommandPaletteItem(
                        id: "nativeTab:\(bundleId):\(t.windowID):\(t.index)",
                        kind: .nativeTab,
                        title: t.title,
                        subtitle: t.isSelected ? "\(appName) \u{00B7} current tab" : appName,
                        icon: icon,
                        keywords: [appName, "tab", t.windowTitle],
                        // Current tab last: Enter on it changes nothing.
                        weight: t.isSelected ? 2.0 : 2.6,
                        recency: Double(1_000 - i),
                        contextBundleIdentifiers: [bundleId],
                        action: .selectNativeTab(bundleIdentifier: bundleId, windowID: t.windowID, index: t.index)
                    )
                }
                self.publish()
            }
            AppSwitcherService.enumerateWindows(of: front) { [weak self] windows in
                guard let self, self.generation == gen else { return }
                self.windowItems = windows.enumerated().compactMap { i, w in
                    let title = w.title.trimmingCharacters(in: .whitespaces)
                    guard !title.isEmpty else { return nil }
                    return CommandPaletteItem(
                        id: "window:\(bundleId):\(w.id)",
                        kind: .window,
                        title: title,
                        subtitle: w.isMinimized ? "\(appName) \u{00B7} minimized" : appName,
                        icon: icon,
                        keywords: [appName, "window"],
                        weight: 2.5,
                        recency: Double(1_000 - i),
                        contextBundleIdentifiers: [bundleId],
                        action: .raiseWindow(bundleIdentifier: bundleId, windowID: w.id)
                    )
                }
                self.publish()
            }
        }

        let needsCache = chromeCacheDate.map { Date().timeIntervalSince($0) > Self.chromeCacheLifetime } ?? true
        let includeChrome = context.includeChrome && ChromeDataService.isInstalled
        let includeEditors = context.includeEditors

        if !includeChrome {
            tabItems = []
            bookmarkItems = []
            historyItems = []
        }
        if !includeEditors { projectItems = [] }
        publish()
        guard includeChrome || includeEditors || SafariProfilesService.isInstalled else { return }

        isLoadingChrome = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if needsCache {
                let safari = Self.safariProfileItems()
                var projects: [CommandPaletteItem] = []
                if includeEditors {
                    for editor in EditorProjectsService.installedEditors() {
                        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier)
                            .map { InstalledAppsService.icon(forPath: $0.path) }
                        for project in EditorProjectsService.recentProjects(for: editor) {
                            projects.append(Self.projectItem(project, icon: icon))
                        }
                    }
                }
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.safariProfileItems = safari
                    if includeEditors { self.projectItems = projects }
                    self.publish()
                }
            }

            guard includeChrome else {
                DispatchQueue.main.async {
                    guard let self, self.generation == gen else { return }
                    self.chromeCacheDate = Date()
                    self.isLoadingChrome = false
                }
                return
            }

            let chromeIcon = ChromeDataService.icon
            let tabs = Self.buildTabs(ChromeDataService.openTabs(), icon: chromeIcon)
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.tabItems = tabs
                if !needsCache { self.isLoadingChrome = false }
                self.publish()
            }

            guard needsCache else { return }
            let profiles = ChromeDataService.profiles()
            var bookmarks: [CommandPaletteItem] = []
            if profiles.count > 1 {
                for (i, profile) in profiles.enumerated() {
                    bookmarks.append(CommandPaletteItem(
                        id: "chromeProfile:\(profile.directory)",
                        kind: .action,
                        title: "Switch to Chrome profile \u{201C}\(profile.name)\u{201D}",
                        subtitle: profile.directory,
                        icon: chromeIcon.map { .image($0) } ?? .symbol("person.crop.circle"),
                        keywords: ["chrome", "profile", "account", profile.name],
                        weight: 2.3,
                        recency: Double(profiles.count - i),
                        contextBundleIdentifiers: [ChromeDataService.bundleIdentifier],
                        action: .switchChromeProfile(directory: profile.directory, name: profile.name)
                    ))
                }
            }
            var history: [CommandPaletteItem] = []
            var seen = Set<String>()
            for profile in profiles {
                for b in ChromeDataService.bookmarks(for: profile) {
                    let key = b.url.absoluteString
                    guard seen.insert(key).inserted else { continue }
                    bookmarks.append(Self.bookmarkItem(b, icon: chromeIcon, showProfile: profiles.count > 1))
                }
            }
            // History is deduplicated by title + host as well as by URL, so
            // one dashboard visited with ten query strings is one row.
            var seenPages = Set<String>()
            for profile in profiles {
                for h in ChromeDataService.history(for: profile) {
                    let key = h.url.absoluteString
                    guard seen.insert(key).inserted,
                          seenPages.insert("\(h.title)|\(h.url.host ?? "")").inserted else { continue }
                    history.append(Self.historyItem(h, icon: chromeIcon, showProfile: profiles.count > 1))
                }
            }
            DispatchQueue.main.async {
                guard let self, self.generation == gen else { return }
                self.bookmarkItems = bookmarks
                self.historyItems = history
                self.chromeCacheDate = Date()
                self.isLoadingChrome = false
                self.publish()
            }
        }
    }

    /// Drop cached Chrome data (after the user toggles the Chrome source off).
    func invalidateChromeCache() {
        chromeCacheDate = nil
        tabItems = []
        bookmarkItems = []
        historyItems = []
        publish()
    }

    private func publish() {
        // A window that is itself a tab would be listed twice; when the
        // front app has native tabs, the tab rows replace its window rows.
        let windows = tabItemsOfFrontApp.isEmpty ? windowItems : []
        items = baseItems + tabItemsOfFrontApp + windows + tabItems + safariProfileItems + projectItems + bookmarkItems + historyItems
    }

    // MARK: - Builders

    private static func buildBase(_ c: Context) -> [CommandPaletteItem] {
        var out: [CommandPaletteItem] = []
        let mine = Bundle.main.bundleIdentifier ?? ""

        // Workspaces. The active one is listed but ranked below the others
        // in the default view, since Enter on it would do nothing visible.
        for (i, profile) in c.profiles.enumerated() {
            let isActive = profile.id == c.activeProfileId
            let appNames = profile.pinnedApps.map(\.displayName)
            out.append(CommandPaletteItem(
                id: "workspace:\(profile.id.uuidString)",
                kind: .workspace,
                title: profile.name,
                subtitle: isActive
                    ? "Current workspace"
                    : (appNames.isEmpty ? "Empty workspace" : appNames.prefix(4).joined(separator: ", ")),
                icon: .symbol(isActive ? "checkmark.square.fill" : "square.grid.2x2.fill"),
                keywords: appNames + ["workspace", "profile"],
                weight: isActive ? 2.4 : 3.0,
                recency: Double(c.profiles.count - i),
                action: .switchWorkspace(profile.id)
            ))
        }

        // Apps: running first (by recency), then installed. One row per
        // bundle identifier.
        let rank = Dictionary(uniqueKeysWithValues: c.recentOrder.enumerated().map { ($1, $0) })
        var seen = Set<String>()
        for app in c.runningApps {
            guard let bundleId = app.bundleIdentifier, bundleId != mine, app.activationPolicy == .regular,
                  seen.insert(bundleId).inserted else { continue }
            let name = app.localizedName ?? bundleId
            let pinned = PinnedApp(bundleIdentifier: bundleId, displayName: name, sortOrder: 0)
            let icon: CommandPaletteItem.Icon = app.bundleURL.map { .image(InstalledAppsService.icon(forPath: $0.path)) } ?? .symbol("app.fill")
            let r = rank[bundleId].map { Double(1_000 - $0) } ?? 0
            out.append(CommandPaletteItem(
                id: "app:\(bundleId)",
                kind: .app,
                title: name,
                subtitle: "Running",
                icon: icon,
                keywords: [],
                weight: 2.0,
                recency: r,
                action: .activateApp(pinned)
            ))
        }
        for app in c.installedApps where seen.insert(app.bundleIdentifier).inserted {
            let pinned = PinnedApp(bundleIdentifier: app.bundleIdentifier, displayName: app.displayName, sortOrder: 0)
            out.append(CommandPaletteItem(
                id: "app:\(app.bundleIdentifier)",
                kind: .app,
                title: app.displayName,
                subtitle: "Open",
                icon: .image(app.icon),
                keywords: [],
                weight: 1.6,
                recency: 0,
                action: .activateApp(pinned)
            ))
        }

        // The user's own commands. Scoped ones carry their app as context so
        // they float up when that app is in front, but are listed everywhere.
        for command in c.customCommands {
            let icon: CommandPaletteItem.Icon = command.appIcon.map { .image($0) } ?? .symbol(command.action.systemImage)
            var subtitle = command.action.summary
            if let app = command.appDisplayName { subtitle = "\(app) \u{00B7} \(subtitle)" }
            out.append(CommandPaletteItem(
                id: "custom:\(command.id.uuidString)",
                kind: .custom,
                title: command.title,
                subtitle: subtitle,
                icon: icon,
                keywords: command.keywordList + [command.appDisplayName ?? ""].filter { !$0.isEmpty },
                weight: 2.6,
                recency: 1,
                contextBundleIdentifiers: command.appBundleIdentifier.map { [$0] } ?? [],
                action: .runCustomCommand(command.id)
            ))
        }

        // HopTab actions.
        if c.canAddWorkspace {
            out.append(CommandPaletteItem(
                id: "action:newWorkspace",
                kind: .action,
                title: "New workspace from what\u{2019}s open",
                subtitle: "Pins the apps you have running right now",
                icon: .symbol("plus.square.on.square"),
                keywords: ["create", "workspace", "profile"],
                weight: 1.2,
                recency: 2,
                action: .newWorkspaceFromRunning
            ))
        }
        for direction in snapActions {
            out.append(CommandPaletteItem(
                id: "snap:\(direction.rawValue)",
                kind: .action,
                title: snapTitle(direction),
                subtitle: "Front window",
                icon: .symbol(snapSymbol(direction)),
                keywords: ["snap", "window", "move", direction.displayName],
                weight: 1.1,
                recency: 0,
                action: .snap(direction)
            ))
        }
        out.append(CommandPaletteItem(
            id: "action:settings",
            kind: .action,
            title: "HopTab Settings",
            subtitle: "Workspaces, shortcuts, automation",
            icon: .symbol("gearshape"),
            keywords: ["preferences", "options"],
            weight: 1.0,
            recency: 1,
            action: .openSettings
        ))
        out.append(CommandPaletteItem(
            id: "action:onboarding",
            kind: .action,
            title: "Set up HopTab again",
            subtitle: "Reopen the welcome tour",
            icon: .symbol("sparkles"),
            keywords: ["onboarding", "welcome", "tour", "help"],
            weight: 0.8,
            recency: 0,
            action: .openOnboarding
        ))
        return out
    }

    private static func buildTabs(_ tabs: [ChromeDataService.OpenTab], icon: NSImage?) -> [CommandPaletteItem] {
        tabs.map { tab in
            CommandPaletteItem(
                id: "tab:\(tab.windowIndex):\(tab.tabIndex)",
                kind: .chromeTab,
                title: tab.title,
                subtitle: tab.url?.host ?? "Chrome",
                icon: icon.map { .image($0) } ?? .symbol("globe"),
                keywords: [tab.url?.host ?? "", tab.url?.absoluteString ?? ""],
                weight: 2.2,
                // Front window first, active tab of each window above its siblings.
                recency: Double(1_000 - tab.windowIndex * 10) + (tab.isActive ? 5 : 0),
                contextBundleIdentifiers: [ChromeDataService.bundleIdentifier],
                action: .activateChromeTab(windowIndex: tab.windowIndex, tabIndex: tab.tabIndex)
            )
        }
    }

    private static func bookmarkItem(_ b: ChromeDataService.Bookmark, icon: NSImage?, showProfile: Bool) -> CommandPaletteItem {
        let host = b.url.host ?? ""
        return CommandPaletteItem(
            id: "bookmark:\(b.url.absoluteString)",
            kind: .bookmark,
            title: b.title,
            subtitle: showProfile ? "\(host) \u{00B7} \(b.profile.name)" : host,
            icon: icon.map { .image($0) } ?? .symbol("bookmark"),
            keywords: [host, b.url.absoluteString],
            weight: 1.3,
            recency: 0,
            contextBundleIdentifiers: [ChromeDataService.bundleIdentifier],
            action: .openURL(b.url, chromeProfileDirectory: b.profile.directory)
        )
    }

    private static func historyItem(_ h: ChromeDataService.HistoryEntry, icon: NSImage?, showProfile: Bool) -> CommandPaletteItem {
        let host = h.url.host ?? ""
        // log2(visits) in the same spirit as the extension; capped so a
        // thousand visits to one dashboard do not swamp everything else.
        let weight = 0.9 + min(log2(Double(h.visitCount) + 1) * 0.12, 0.6)
        return CommandPaletteItem(
            id: "history:\(h.url.absoluteString)",
            kind: .history,
            title: h.title,
            subtitle: showProfile ? "\(host) \u{00B7} \(h.profile.name)" : host,
            icon: icon.map { .image($0) } ?? .symbol("clock"),
            keywords: [host, h.url.absoluteString],
            weight: weight,
            recency: h.lastVisit,
            contextBundleIdentifiers: [ChromeDataService.bundleIdentifier],
            action: .openURL(h.url, chromeProfileDirectory: h.profile.directory)
        )
    }

    /// One "Switch to Safari profile" row per profile Safari lists in its
    /// File menu (cached names when Safari is closed). Off-main.
    private static func safariProfileItems() -> [CommandPaletteItem] {
        guard SafariProfilesService.isInstalled else { return [] }
        let names = SafariProfilesService.profileNames()
        let icon = SafariProfilesService.icon
        return names.enumerated().map { i, name in
            CommandPaletteItem(
                id: "safariProfile:\(name)",
                kind: .action,
                title: "Switch to Safari profile \u{201C}\(name)\u{201D}",
                subtitle: "Safari",
                icon: icon.map { .image($0) } ?? .symbol("person.crop.circle"),
                keywords: ["safari", "profile", "account", name],
                weight: 2.3,
                recency: Double(names.count - i),
                contextBundleIdentifiers: [SafariProfilesService.bundleIdentifier],
                action: .switchSafariProfile(name: name)
            )
        }
    }

    private static func projectItem(_ p: EditorProjectsService.Project, icon: NSImage?) -> CommandPaletteItem {
        let parent = p.url.deletingLastPathComponent().path
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
        return CommandPaletteItem(
            id: "project:\(p.editor.bundleIdentifier):\(p.url.path)",
            kind: .project,
            title: p.name,
            subtitle: "\(parent) \u{00B7} \(p.editor.name)",
            icon: icon.map { .image($0) } ?? .symbol("folder"),
            keywords: [p.url.path, p.editor.name, "project", "repo"],
            weight: 1.4,
            recency: p.lastOpened,
            contextBundleIdentifiers: [p.editor.bundleIdentifier],
            action: .openProject(p.url, editorBundleIdentifier: p.editor.bundleIdentifier)
        )
    }

    private static func snapTitle(_ d: SnapDirection) -> String {
        switch d {
        case .full: return "Maximize window"
        case .center: return "Center window"
        case .undo: return "Undo last window move"
        case .nextMonitor: return "Move window to next screen"
        case .previousMonitor: return "Move window to previous screen"
        default: return "Snap window to \(d.displayName.lowercased())"
        }
    }

    private static func snapSymbol(_ d: SnapDirection) -> String {
        switch d {
        case .left: return "rectangle.lefthalf.filled"
        case .right: return "rectangle.righthalf.filled"
        case .topHalf: return "rectangle.tophalf.filled"
        case .bottomHalf: return "rectangle.bottomhalf.filled"
        case .full: return "rectangle.fill"
        case .center: return "rectangle.center.inset.filled"
        case .undo: return "arrow.uturn.backward"
        case .nextMonitor, .previousMonitor: return "display.2"
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return "square.split.2x2"
        default: return "rectangle.split.3x1"
        }
    }
}
