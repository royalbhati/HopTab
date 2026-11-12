# Changelog

All notable changes to HopTab are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries below were reconstructed from git history and published release notes.
Versions before 1.1.0 predate this file and are not covered.

## [Unreleased]

Everything here is on `main` and **has not shipped in a release**. The last
published release is 1.4.0 (18 Jun 2026); the newest app-code commit is
`86beea7` (22 Aug 2026).

### Added
- **Custom palette commands.** Settings → Command Palette lets you add your own ⌥K rows: open a link, open a file or folder, press a shortcut inside an app, run a shell command, or paste text. Scope a command to an app and it ranks first when that app is in front. ⌘N in the palette turns the current query into a new command. Commands export and import as JSON so packs can be shared.
- `hoptab://settings/<section>` deep link opens Settings at a section (workspaces, shortcuts, palette, calendar, tracking, breaks, automation, general).
- **⌥K command palette.** One search over your workspaces, running and installed apps, Google Chrome open tabs, bookmarks and 30 days of history (every profile), recent VSCodium / VS Code / Cursor projects, and HopTab actions (snap, undo, new workspace, settings). Enter opens, ⌘Enter opens a URL in a new Chrome window, ⌘⌫ closes a Chrome tab, ⌘1–9 jumps to a row. Anything unmatched opens as a URL or a web search.
- **Context-aware ranking.** The palette knows which app was in front when you pressed ⌥K: in Chrome, tabs and history come first; in your editor, projects do. The front app's own row is hidden.
- Shortcut, Chrome access and on/off switch live under Settings → Shortcuts → Command Palette. Reading Chrome tabs asks once for Automation access to Chrome.
- Chrome profile rows in the palette raise the profile’s existing window instead of opening a new tab; a new window opens only when the profile has none.
- **Browser profiles per workspace.** Tie a workspace to a Chrome or Safari profile (Settings → Workspaces → Behaviour). Switching to the workspace brings that profile’s window to the front, opening one if needed. Safari has no profile API, so HopTab reads its File menu and window toolbars through Accessibility.
- ⌥K lists “Switch to Safari profile” rows next to the Chrome ones.
- **Guided onboarding.** Three steps: grant Accessibility, build a workspace from what’s running, then a tour that asks you to press each key (⌘Tab, ⌥Tab, ⌥`, ⌥K, a snap) and ticks it off only when HopTab sees it happen.
- **Faster switcher and palette.** Opening ⌥Tab or ⌥K no longer rebuilds its window each time, app icons are cached, and the Focus Border / Focus Dimming features ask the newly active app for its window off the main thread. Switching apps used to stall HopTab for 150–250 ms each time.
- Palette hover no longer steals the keyboard selection when the pointer merely rests over the list.

### Added

- **Two switchers.** "Replace ⌘Tab" (Settings → Shortcuts, or the onboarding
  toggle) puts HopTab's all-apps switcher on ⌘Tab: the active workspace's
  apps first, every other running app after in most-recently-used order.
  The configurable preset (⌥Tab by default) is now strictly the workspace
  switcher — only the current workspace's apps. The old "⌘ Command + Tab"
  preset is migrated to the new toggle on first launch.
- **Build workspaces from inside the switcher** — while either switcher is
  open, press `P` to pin/unpin the highlighted app to the active workspace,
  `1`–`9` to toggle it in any workspace, `N` to create a new workspace
  containing it, or `⌫` to unpin it. The footer shows which
  profiles already contain the app. No Settings trip needed to build a
  profile.
- **Onboarding is two screens** — Accessibility, then "Your First
  Workspace": a workspace pre-filled from the apps already running, a
  "Use ⌘Tab for HopTab" toggle, and the first hop detected live on the same
  page. The welcome, separate try-it and summary screens are gone.
- **Menu bar panel redesigned around workspaces** — every profile is a row
  with its app icons and hotkey; the active one is marked and any other is
  one click away. New "New workspace from what's open" creates a profile
  pinned with the apps running right now. The snap grid is unchanged; the
  Focus/Pomodoro row is gone (those features moved to Labs).
- **Launch at login** — a "Launch at login" toggle in Settings, backed by
  `SMAppService`. Handles the `.requiresApproval` state by linking straight to
  System Settings → Login Items.
- **Grow / shrink split** — resize the shared edge between two snapped windows
  without re-snapping either. Bound to `Ctrl+Opt+=` and `Ctrl+Opt+-`
  (Rectangle's Larger/Smaller keys) and listed under a new "Resize" group in
  the shortcut settings.
- **Space-aware profiles** — profiles can be pinned to a specific macOS Space.
  Activating a profile switches to its Space, and a per-profile
  "Move windows to this desktop" toggle pulls that profile's windows onto the
  current Space via `CGSMoveWindowsToManagedSpace`. A new `SpaceService`
  wraps the private CGS Space APIs (enumerate Spaces, resolve a window's Space,
  move windows, switch Space).
- **SIP awareness** — Settings detects System Integrity Protection status and
  shows whether "Advanced space control" is actually available, instead of
  silently failing when the CGS calls are restricted.
- **Reduced Motion support in onboarding** — onboarding reads
  `@Environment(\.accessibilityReduceMotion)` and drops its shimmer, scale and
  transition animations when the system setting is on.
- **Drag-away restore** — dragging a snapped window away from its position
  restores its pre-snap size under the cursor (Rectangle-style "unsnap"). On by
  default; toggle is "Restore size when dragging away" in Settings → Snapping.
- **Bunch-style launch orchestration** — per-app launch options within a
  profile: priority groups launched in order, an optional per-app launch delay,
  and documents/URLs to open with the app. Each group waits for the previous
  group's apps to become ready (30s cap per group) before starting the next.
- **Custom Layouts upsell** — the layout picker now explains what Pro's
  exact-percentage custom layouts do instead of silently hiding the feature.

### Changed
- Menu bar: "New workspace from what's open" now opens an inline picker. Name the workspace, tick exactly the running apps you want (All / Clear), Create. Each workspace row's menu also gained Delete Workspace with a confirmation.
- **Settings reorganised around features.** Calendar, Time Tracking and Screen Breaks each get their own sidebar section with a showcase header that explains what the feature does and how to set it up. Automation keeps Schedule, Focus modes, Displays, Window Rules and the license. The window is larger (1040×720 default) and the sidebar marks Pro sections until a license is active.
- **Workspaces pane**: a proper header with the workspace’s summary, an inline hotkey row, a pinned-apps list that no longer scrolls inside the page, and an app picker laid out as a grid with search.
- **Calendar pane**: Meeting Mode settings are three tiles (Switch to / Remind / After it ends), events are a card grouped by day with a Now marker, and every per-event action (choose workspace, Pomodoro, open link) lives in one ⋯ menu.
- Switching to an app with several windows no longer pops the window picker and blocks typing. It is now the opt-in "Ask which window after switching" setting; Space in the switcher still lists windows.

- **Shortcuts page shows the everyday set first.** Sixths, ninths,
  move-to-edge, vertical thirds and the rarer sizes (almost-maximize,
  full-height, centre-half, centre-keep-size) are collapsed under
  "More (Rectangle extras)". Existing bindings in those groups still fire.
- **Pro is now one promise: HopTab switches your workspace for you.** Stable
  Pro = calendar, schedule, Focus mode, display profiles, window rules,
  custom layouts, unlimited profiles, window undo. Time tracking, per-app
  budgets, Pomodoro, focus sessions, screen breaks and auto-declutter join
  tiling/border/dimming/themes under Labs (off by default). The Wellbeing
  sidebar section is removed; its search entries point at Pro → Labs.

- **Settings collapsed to four sections** — Workspaces, Shortcuts, Automation
  (Pro: calendar, schedule, Focus mode, displays, window rules, Labs, license)
  and General. The Workspaces pane is master-detail: a chip row picks the
  workspace, then its name, hotkey, apps (with an inline add-app search),
  layout and behaviour. The old profile list, separate profile picker and
  pinned-apps list showed the same choice three times on one page.
  Time Tracking moved out of the Automation card into Labs. Each sidebar row carries a one-line subtitle. Search entries and
  deep links remapped. `SettingsView.swift` split into
  `Views/Settings/*Pane.swift` files.
- **Settings redesign** — Settings moved to a `NavigationSplitView` sidebar
  layout.

### Build / Release

- `scripts/generate-pro-stub.sh` generates a compile-only stub for the
  closed-source `HopTabPro` package, so a fresh clone and CI can build the
  free-tier app. Fixes CI, which had failed on every run since v1.2.0 with
  `The folder "HopTabPro" doesn't exist.`
- `release.yml` now produces a Developer ID signed, hardened-runtime, notarized
  and stapled build, verifies it with `codesign`/`spctl`/`stapler` before
  publishing, and **fails** if the signing secrets are absent rather than
  falling back to ad-hoc signing.
- Release assets now publish a SHA-256 in the release notes.
- Added `HopTab/HopTab.entitlements` (calendar access only), matching the
  entitlements on the shipped 1.4.0 binary.
  **`HopTab.xcodeproj` still has `CODE_SIGN_ENTITLEMENTS = ""` and
  `CODE_SIGN_STYLE = Automatic`** — the release workflow passes both on the
  `xcodebuild` command line to compensate. The project setting should be
  pointed at `HopTab/HopTab.entitlements`.
- README no longer tells users to run `xattr` on a notarized app.
- `hoptab.rb` resynced with the published tap (1.4.0) and gained `livecheck`,
  `auto_updates false` and a cache path in `zap`.

### Website (unreleased, not part of the app)

- Rewritten "move window to another monitor" guide; new "advanced space
  control" guide; Download replaces GitHub in the header CTA; hero copy
  sharpened; inactive X Ads pixel scaffold.

### Changed
- **Menu bar panel redesigned.** Workspaces are the menu: each row shows an icon tile, name, app count, running count, browser profile and hotkey; the active one is tinted; hover shows a ⋯ menu with Save & Close, Restore, Apply Layout and Edit. A new "Now" block shows the current or next meeting, a running focus session or Pomodoro, the time to the next screen break (with Break now / Skip) and today's tracked time. The 12-cell snap grid is now one row (left, right, full, center, undo); the full picker stays in Settings. Footer is plain text buttons.

### Fixed
- Snap shortcuts (⌃⌥← and friends) now work while HopTab itself is in front — with the menu popover open or Settings focused. They used to be passed through untouched there, so nothing happened.
- Snapping HopTab's own Settings window crashed the app: it queried its own Accessibility server from a background queue. HopTab's own windows now move through AppKit directly.
- The menu's "to switch" hint showed the modifier twice ("⌥Option + `") for a custom workspace shortcut.

### Removed
- **Focus Border, Focus Dimming, Themes, Per-Profile Visuals and Auto-Declutter** are gone. They were experimental, cost main-thread time on every app switch, and pulled attention from the features HopTab is actually about. BSP auto-tiling stays in Labs.

## [1.4.0] - 2026-06-18

### Added

- **Focus Sessions** (Pro) — time-boxed focus scoped to a profile's apps, with
  nudges when you stray outside them.
- **Per-app time tracking** (Pro) — where the hours go within each profile.
- **Meeting HUD** (Pro) — next/active meeting in the menu bar with one-click Join.
- **Weekly digest** (Pro) — start-of-week summary of tracked time.
- **`hoptab://` URL scheme** — deep links for Raycast, Shortcuts, Stream Deck
  and `open` from the terminal.
- Update feed (`website/update.json`) behind the in-app update check.
- Public landing site under `website/`.

### Changed

- Redesigned app switcher overlay — smoother animation, clearer selection, and
  the focused app's name.
- Settings reorganized into 6 sections; Pro features moved to a card-based layout.

### Fixed

- Drag-to-snap works again.
- Undo/Redo snap shortcuts were swapped.
- Meeting reminder Join / Snooze / "not attending" buttons are reliable.
- Screen-break skip no longer crashes.
- Time tracking no longer logs phantom hours after sleep or force-quit.
- Crash when switching profiles (`54f11c3`).
- Assorted performance work across overlay, hotkey and drag-snap paths (`46fb1f1`).

> **Tagging note:** the `v1.4.0` git tag points at `78c3239` — the same commit as
> `v1.3.1` — while the actual "Release 1.4.0" commit (`c49ec65`) landed afterwards.
> The published 1.4.0 binary was built by hand from `c49ec65` on the maintainer's
> Mac, so the tag does not describe the shipped artifact. Future releases build
> from the tag in CI.

## [1.3.1] - 2026-04-19

### Changed

- Dropped the `--no-quarantine` flag from the Homebrew install instructions
  (contributed by @Qhilm, [#23](https://github.com/royalbhati/HopTab/pull/23)).

## [1.3.0] - 2026-04-15

### Added

- Window **redo** shortcut (`Ctrl+Opt+Shift+Z`).
- Per-app display assignment within a profile.
- Draggable edge resizing in the custom layout editor.
- Numeric inputs in the custom layout editor.

- A stray committed `HopTab.app` build product.

## [1.2.0] - 2026-03-30

### Added

- **HopTab Pro** ($5 one-time) — time tracking, calendar auto-switch with
  Zoom/Teams/Meet link detection and a fullscreen meeting reminder, time-based
  scheduling with day-of-week filters, macOS Focus mode integration, display
  auto-profiles, unlimited window rules, exact-percentage custom layouts, and
  unlimited profiles.
- **Drag-to-snap** — drag a window to an edge or corner with a translucent
  preview of where it will land.
- Window rules ("Chrome always left half on launch") — 2 free, unlimited with Pro.
- Licence validation worker (`hoptab-license-worker/`).
- Empty-state overlay when no apps are pinned; running-state indicators on app
  icons; profile delete confirmation; shortcut rejection hints; onboarding skip
  button.

### Changed

- Settings moved to sidebar navigation, with Pro features folded into the
  relevant sections and a dedicated Pro showcase page.
- Snap shortcuts laid out in a 2-column grid.

## [1.1.1] - 2026-03-26

### Changed

- Updated the in-app update feed URL.

## [1.1.0] - 2026-03-25

### Added

- Space-aware window picker — filters to the current Space using
  `CGWindowListCopyWindowInfo`.
- Universal snap cycling (`Ctrl+Opt+.` and `Ctrl+Opt+,`) through all 15 positions.
- Custom layout editor with zone splitting, presets, and edit/delete.
- Display-aware session snapshots, keyed by display configuration for
  dock/undock workflows.
- `Cmd+Tab` preset to replace the native macOS switcher.
- Global window tiling and snap shortcuts.

### Fixed

- Menu click issue in layout zone assignment on macOS Sequoia.

[Unreleased]: https://github.com/royalbhati/HopTab/compare/v1.4.0...HEAD
[1.4.0]: https://github.com/royalbhati/HopTab/releases/tag/v1.4.0
[1.3.1]: https://github.com/royalbhati/HopTab/releases/tag/v1.3.1
[1.3.0]: https://github.com/royalbhati/HopTab/releases/tag/v1.3.0
[1.2.0]: https://github.com/royalbhati/HopTab/releases/tag/v1.2.0
[1.1.1]: https://github.com/royalbhati/HopTab/releases/tag/v1.1.1
[1.1.0]: https://github.com/royalbhati/HopTab/releases/tag/v1.1.0
