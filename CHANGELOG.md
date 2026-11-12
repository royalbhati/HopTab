# Changelog

All notable changes to HopTab are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Entries below were reconstructed from git history and published release notes.
Versions before 1.1.0 predate this file and are not covered.

## [Unreleased]

## [1.5.0] - 2026-11-12

### Added
- **⌥K command palette.** One search over your workspaces, running and
  installed apps, Google Chrome tabs, bookmarks and 30 days of history (every
  profile), recent VSCodium / VS Code / Cursor projects, and HopTab actions
  (snap, undo, new workspace, settings). Enter opens, ⌘Enter opens a URL in a
  new Chrome window, ⌘⌫ closes a Chrome tab, ⌘1–9 jumps to a row. Anything
  unmatched opens as a URL or a web search. The palette ranks by the app that
  was in front when you pressed ⌥K: in Chrome, tabs and history come first; in
  your editor, projects do.
- **Custom palette commands.** Settings → Command Palette lets you add your own
  rows: open a link, file or folder, press a shortcut inside an app, run a
  shell command, or paste text. Scope a command to an app and it ranks first
  there. ⌘N in the palette turns the current query into a new command.
  Commands export and import as JSON.
- **Two switchers.** "Replace ⌘Tab" (Settings → Shortcuts, or the onboarding
  toggle) puts HopTab's all-apps switcher on ⌘Tab: the active workspace's apps
  first, every other running app after in most-recently-used order. ⌥Tab is
  now strictly the workspace switcher. The old "⌘ Command + Tab" preset is
  migrated to the toggle on first launch.
- **Build workspaces from inside the switcher.** While either switcher is
  open, `P` pins or unpins the highlighted app to the active workspace, `1`–`9`
  toggles it in any workspace, `N` creates a new workspace containing it, `⌫`
  unpins it. The footer shows which workspaces already contain the app.
- **Browser profiles per workspace.** Tie a workspace to a Chrome or Safari
  profile (Settings → Workspaces → Behaviour). Switching brings that profile's
  window to the front, opening one if needed. The palette lists "Switch to
  Chrome/Safari profile" rows.
- **Menu bar panel rebuilt around workspaces.** Each row shows an icon tile,
  name, app and running count, browser profile and hotkey; the active one is
  tinted; hover shows a ⋯ menu with Save & Close, Restore, Apply Layout, Edit
  and Delete. "New workspace from what's open" expands into a picker: name it,
  tick the running apps you want (All / Clear), Create. A "Now" block shows the
  current or next meeting, a running focus session or Pomodoro, the time to the
  next screen break (Break now / Skip) and today's tracked time. The snap grid
  is one row (left, right, full, centre, undo).
- **Guided onboarding.** Three steps: grant Accessibility, build a workspace
  from what's running (with the "Use ⌘Tab for HopTab" toggle), then a tour
  that asks you to press each key (⌘Tab, ⌥Tab, ⌥`, ⌥K, a snap) and ticks it
  off only when HopTab sees it happen. Honours Reduce Motion.
- **Launch at login** toggle in Settings, backed by `SMAppService`.
- **Grow / shrink split.** Resize the shared edge between two snapped windows
  without re-snapping. `Ctrl+Opt+=` and `Ctrl+Opt+-`, under a new "Resize"
  group in the shortcut settings.
- **Space-aware profiles.** Pin a profile to a macOS Space; activating it
  switches there, and "Move windows to this desktop" pulls its windows onto the
  current Space. Settings shows whether advanced space control is available
  under System Integrity Protection.
- **Drag-away restore.** Dragging a snapped window away restores its pre-snap
  size under the cursor. Toggle: Settings → Snapping → "Restore size when
  dragging away".
- **Launch orchestration per workspace.** Priority groups launched in order, an
  optional per-app delay, and documents or URLs to open with the app.
- `hoptab://settings/<section>` deep links open Settings at a section.
- Custom Layouts upsell in the layout picker instead of a hidden feature.

### Changed
- **Settings reorganised around features.** Sidebar sections: Workspaces,
  Shortcuts, Calendar, Time Tracking, Screen Breaks, Automation, General. Each
  Pro section has a showcase header explaining the feature and marks itself as
  Pro until a license is active. Workspaces is master-detail with an inline
  hotkey row and a searchable app grid. Calendar shows Meeting Mode as three
  tiles and events as a card grouped by day with a Now marker.
- **Shortcuts page shows the everyday set first.** Sixths, ninths,
  move-to-edge, vertical thirds and the rarer sizes are collapsed under
  "More (Rectangle extras)". Existing bindings still fire.
- **Pro is one promise: HopTab switches your workspace for you.** Stable Pro
  is calendar, schedule, Focus mode, display profiles, window rules, custom
  layouts, unlimited profiles and window undo. Time tracking, budgets,
  Pomodoro, focus sessions, screen breaks and BSP tiling live under Labs.
- Opening ⌥Tab or ⌥K no longer rebuilds the window each time and app icons are
  cached; switching apps used to stall HopTab for 150–250 ms.
- Switching to an app with several windows no longer pops the window picker.
  It is the opt-in "Ask which window after switching" setting.
- Palette hover no longer steals the keyboard selection when the pointer
  merely rests over the list.

### Fixed
- Snap shortcuts (⌃⌥← and friends) now work while HopTab itself is in front,
  with the menu open or Settings focused.
- Snapping HopTab's own Settings window crashed the app. Its own windows now
  move through AppKit directly.
- The menu's "to switch" hint showed the modifier twice for a custom workspace
  shortcut.
- CI had failed on every run since 1.2.0 because the closed-source `HopTabPro`
  package was missing; `scripts/generate-pro-stub.sh` now generates a
  compile-only stub for the free build.

### Removed
- **Focus Border, Focus Dimming, Themes, Per-Profile Visuals and Auto-Declutter.**
  They were experimental, cost main-thread time on every app switch, and pulled
  attention from what HopTab is about.

### Build / Release
- `release.yml` produces a Developer ID signed, hardened-runtime, notarized and
  stapled build, verifies it before publishing, and fails if the signing
  secrets are absent instead of falling back to ad-hoc signing. Release notes
  carry a SHA-256.
- Added `HopTab/HopTab.entitlements` (calendar and Apple Events).
- README no longer tells users to run `xattr` on a notarized app.
- `hoptab.rb` resynced with the published tap and gained `livecheck`.

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

[Unreleased]: https://github.com/royalbhati/HopTab/compare/v1.5.0...HEAD
[1.5.0]: https://github.com/royalbhati/HopTab/compare/v1.4.0...v1.5.0
[1.4.0]: https://github.com/royalbhati/HopTab/releases/tag/v1.4.0
[1.3.1]: https://github.com/royalbhati/HopTab/releases/tag/v1.3.1
[1.3.0]: https://github.com/royalbhati/HopTab/releases/tag/v1.3.0
[1.2.0]: https://github.com/royalbhati/HopTab/releases/tag/v1.2.0
[1.1.1]: https://github.com/royalbhati/HopTab/releases/tag/v1.1.1
[1.1.0]: https://github.com/royalbhati/HopTab/releases/tag/v1.1.0
