import AppKit

/// One tile in the app switcher.
///
/// The switcher shows two groups in one keyboard-navigable list: the active
/// profile's pinned apps first, then every other running app in most-recently
/// activated order (what the native Cmd+Tab shows). `isPinned` tells the
/// overlay which group a tile belongs to and which hint to show for it.
struct SwitcherEntry: Identifiable, Equatable {
    let app: PinnedApp
    let isPinned: Bool

    var id: String { app.bundleIdentifier }

    /// Build the switcher list.
    ///
    /// - Parameters:
    ///   - pinned: the active profile's apps, already in display order.
    ///   - running: regular (Dock-visible) running applications.
    ///   - recentOrder: bundle identifiers, most recently activated first.
    ///     Apps not in this list sort after it, alphabetically.
    ///   - includeRunning: `false` restores the pinned-only switcher.
    ///   - excluding: bundle identifiers never to show (HopTab itself).
    static func build(
        pinned: [PinnedApp],
        running: [NSRunningApplication],
        recentOrder: [String],
        includeRunning: Bool,
        excluding: Set<String> = []
    ) -> [SwitcherEntry] {
        var entries = pinned
            .filter { !excluding.contains($0.bundleIdentifier) }
            .map { SwitcherEntry(app: $0, isPinned: true) }
        guard includeRunning else { return entries }

        let pinnedIDs = Set(pinned.map(\.bundleIdentifier))
        let rank = Dictionary(uniqueKeysWithValues: recentOrder.enumerated().map { ($1, $0) })

        let others = running
            .compactMap { app -> PinnedApp? in
                guard let bundleID = app.bundleIdentifier,
                      !pinnedIDs.contains(bundleID),
                      !excluding.contains(bundleID)
                else { return nil }
                return PinnedApp(
                    bundleIdentifier: bundleID,
                    displayName: app.localizedName ?? bundleID,
                    sortOrder: 0
                )
            }
            .sorted { a, b in
                let ra = rank[a.bundleIdentifier] ?? Int.max
                let rb = rank[b.bundleIdentifier] ?? Int.max
                if ra != rb { return ra < rb }
                return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
            }

        entries += others.map { SwitcherEntry(app: $0, isPinned: false) }
        return entries
    }
}
