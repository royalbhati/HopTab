import AppKit

/// One row in the ⌥K command palette.
///
/// The palette is for things that are *not yet in front of you*: a workspace,
/// an app, a browser tab, a page from last week, a HopTab action. Every row
/// carries the text it is matched against, a weight that says how much a
/// match of its kind is worth, and the action Enter performs.
struct CommandPaletteItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case workspace
        case app
        case chromeTab
        case bookmark
        case history
        case project
        /// A window of the app that was in front when ⌥K was pressed.
        case window
        /// A native macOS tab of the front app's window.
        case nativeTab
        case action
        /// A command the user added themselves (Settings → Command Palette).
        case custom
        /// Synthesised from the query itself: open as URL or web search.
        case fallback
    }

    enum Icon: Equatable {
        case image(NSImage)
        case symbol(String)
    }

    enum Action: Equatable {
        case switchWorkspace(UUID)
        case activateApp(PinnedApp)
        case activateChromeTab(windowIndex: Int, tabIndex: Int)
        case openURL(URL, chromeProfileDirectory: String?)
        case openProject(URL, editorBundleIdentifier: String)
        /// Raise (or open) the window of a Chrome profile.
        case switchChromeProfile(directory: String, name: String)
        /// Raise (or open) the window of a Safari profile.
        case switchSafariProfile(name: String)
        case raiseWindow(bundleIdentifier: String, windowID: UInt32)
        case selectNativeTab(bundleIdentifier: String, windowID: UInt32, index: Int)
        case snap(SnapDirection)
        case newWorkspaceFromRunning
        case openSettings
        case openOnboarding
        case runCustomCommand(UUID)
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let icon: Icon
    /// Extra strings the fuzzy matcher may hit (host, URL, workspace apps…).
    let keywords: [String]
    /// Multiplier on the match score. Workspaces outrank tabs outrank history.
    let weight: Double
    /// Secondary sort when scores tie, higher first (recency, visit count).
    let recency: Double
    /// Apps this row "belongs" to. When one of them is frontmost at ⌥K time
    /// the row is boosted: Chrome tabs in Chrome, projects in the editor.
    var contextBundleIdentifiers: Set<String> = []
    let action: Action
    /// Title and keywords, lowercased once, as scalar arrays the fuzzy
    /// scorer can walk without allocating per keystroke.
    let searchScalars: [[Unicode.Scalar]]

    init(
        id: String,
        kind: Kind,
        title: String,
        subtitle: String,
        icon: Icon,
        keywords: [String],
        weight: Double,
        recency: Double,
        contextBundleIdentifiers: Set<String> = [],
        action: Action
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.keywords = keywords
        self.weight = weight
        self.recency = recency
        self.contextBundleIdentifiers = contextBundleIdentifiers
        self.action = action
        self.searchScalars = ([title] + keywords).map { Array($0.lowercased().unicodeScalars) }
    }

    var kindLabel: String {
        switch kind {
        case .workspace: return "Workspace"
        case .app: return "App"
        case .chromeTab: return "Tab"
        case .bookmark: return "Bookmark"
        case .history: return "History"
        case .project: return "Project"
        case .window: return "Window"
        case .nativeTab: return "Tab"
        case .action: return "Action"
        case .custom: return "Custom"
        case .fallback: return ""
        }
    }

    static func == (lhs: CommandPaletteItem, rhs: CommandPaletteItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Fuzzy matching

/// Subsequence matcher in the Arc / Raycast family: every query character
/// must appear in order; contiguous runs and word starts score higher; a
/// match near the start of the string beats one deep inside it.
enum FuzzyScorer {
    /// Score `query` against `text`. `nil` when the query is not a
    /// subsequence of the text. Higher is better. Case-insensitive.
    static func score(_ query: String, in text: String) -> Double? {
        score(Array(query.lowercased().unicodeScalars), in: Array(text.lowercased().unicodeScalars))
    }

    /// Scalar form: both inputs already lowercased.
    static func score(_ q: [Unicode.Scalar], in t: [Unicode.Scalar]) -> Double? {
        if q.isEmpty { return 0 }
        guard q.count <= t.count else { return nil }

        var score: Double = 0
        var ti = 0
        var previousMatch = -2
        var firstMatch = -1

        for qc in q {
            var found = false
            while ti < t.count {
                let tc = t[ti]
                if tc == qc {
                    found = true
                    // A scattered character is worth little; what the user
                    // means is almost always a run or a word start.
                    var gain: Double = 0.4
                    if previousMatch == ti - 1 { gain += 2.2 }             // contiguous run
                    if ti == 0 || isSeparator(t[ti - 1]) { gain += 1.6 }   // word start
                    if firstMatch < 0 { firstMatch = ti }
                    score += gain
                    previousMatch = ti
                    ti += 1
                    break
                }
                ti += 1
            }
            if !found { return nil }
        }

        // Prefer matches that start early and texts that are not much longer
        // than the query, so "mail" ranks Mail above "Thunderbird mailing list".
        score -= Double(firstMatch) * 0.05
        score -= Double(t.count - q.count) * 0.01
        return max(score, 0.01)
    }

    /// Best score across several candidate strings.
    static func best(_ query: String, in candidates: [String]) -> Double? {
        var best: Double?
        for c in candidates {
            guard let s = score(query, in: c) else { continue }
            if best == nil || s > best! { best = s }
        }
        return best
    }

    static func best(_ q: [Unicode.Scalar], in candidates: [[Unicode.Scalar]]) -> Double? {
        var best: Double?
        for c in candidates {
            guard let s = score(q, in: c) else { continue }
            if best == nil || s > best! { best = s }
        }
        return best
    }

    private static func isSeparator(_ c: Unicode.Scalar) -> Bool {
        !(CharacterSet.alphanumerics.contains(c))
    }
}

// MARK: - Ranking

extension CommandPaletteItem {
    /// Boost for rows that belong to the frontmost app.
    static let contextBoost: Double = 1.8
    /// Rows tied to some *other* app (Chrome tabs while you are in Xcode)
    /// sink below workspaces and running apps instead of leading the list.
    static let outOfContextPenalty: Double = 0.5

    /// Rank `items` for `query`. Empty query returns the default order:
    /// in-context rows first, then by weight, then recency. Non-empty query
    /// drops non-matches. `frontmost` is the app that had focus when the
    /// palette opened; its own app row is hidden (you are already there).
    static func rank(
        _ items: [CommandPaletteItem],
        query: String,
        frontmost: String? = nil,
        limit: Int = 40
    ) -> [CommandPaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        func inContext(_ item: CommandPaletteItem) -> Bool {
            guard let frontmost else { return false }
            return item.contextBundleIdentifiers.contains(frontmost)
        }
        func effectiveWeight(_ item: CommandPaletteItem) -> Double {
            if item.contextBundleIdentifiers.isEmpty { return item.weight }
            return item.weight * (inContext(item) ? contextBoost : outOfContextPenalty)
        }
        func hidden(_ item: CommandPaletteItem) -> Bool {
            if let frontmost, item.kind == .app, item.id == "app:\(frontmost)" { return true }
            return false
        }

        // Rank by index and copy only the rows that make the cut. The item
        // struct carries several reference-counted fields, so filtering and
        // sorting thousands of them by value cost ~20 ms per keystroke.
        if trimmed.isEmpty {
            var order: [(index: Int, weight: Double, recency: Double)] = []
            order.reserveCapacity(min(items.count, 512))
            for (i, item) in items.enumerated() {
                if hidden(item) { continue }
                if item.kind == .history && !inContext(item) { continue }  // history only when searched, or in Chrome
                order.append((i, effectiveWeight(item), item.recency))
            }
            order.sort { a, b in
                if a.weight != b.weight { return a.weight > b.weight }
                return a.recency > b.recency
            }
            return order.prefix(limit).map { items[$0.index] }
        }

        var scored: [(index: Int, score: Double, recency: Double)] = []
        scored.reserveCapacity(256)
        let q = Array(trimmed.lowercased().unicodeScalars)
        for (i, item) in items.enumerated() {
            if hidden(item) { continue }
            guard let s = FuzzyScorer.best(q, in: item.searchScalars) else { continue }
            scored.append((i, s * effectiveWeight(item), item.recency))
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.recency > b.recency
        }
        return scored.prefix(limit).map { items[$0.index] }
    }

    /// The row that catches whatever the index does not: a URL if the query
    /// looks like one, otherwise a web search.
    static func fallback(for query: String) -> CommandPaletteItem? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let url = Self.urlIfLooksLikeOne(trimmed) {
            return CommandPaletteItem(
                id: "fallback:url",
                kind: .fallback,
                title: "Open \(url.host ?? trimmed)",
                subtitle: url.absoluteString,
                icon: .symbol("globe"),
                keywords: [],
                weight: 0,
                recency: 0,
                action: .openURL(url, chromeProfileDirectory: nil)
            )
        }
        var comps = URLComponents(string: "https://www.google.com/search")!
        comps.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return CommandPaletteItem(
            id: "fallback:search",
            kind: .fallback,
            title: "Search the web for \u{201C}\(trimmed)\u{201D}",
            subtitle: "Google",
            icon: .symbol("magnifyingglass"),
            keywords: [],
            weight: 0,
            recency: 0,
            action: .openURL(comps.url!, chromeProfileDirectory: nil)
        )
    }

    private static func urlIfLooksLikeOne(_ s: String) -> URL? {
        if s.contains(" ") { return nil }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return URL(string: s) }
        if s.hasPrefix("localhost") || s.range(of: #"^[\w.-]+\.[a-z]{2,}(/.*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return URL(string: "https://" + s)
        }
        return nil
    }
}
