# HopTab

**The workspace manager macOS should've shipped with.**

Pin apps. Tile windows. Switch profiles. All with a single shortcut.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## The Problem

You have 10 apps open. You're actively using 2. But every `Cmd+Tab` forces you to cycle through all of them. HopTab fixes this.

**Pin** the apps you're focused on. **Option+Tab** hops only between those. Everything else stays out of the way.

## What It Does

### Focused App Switching
Pin 2-5 apps per workflow. `Option+Tab` cycles through only your pinned apps. Release to switch. That's it.

### Window Layouts
Pick a layout template (split, thirds, quarters). Assign apps to zones. Apply with one click and your windows snap into place.

### Profiles
Create profiles for different workflows — Coding, Design, Writing. Each carries its own pinned apps, layout, hotkey, and desktop assignment. Swipe to a different desktop and your profile switches automatically.

### Window Picker
When an app has multiple windows, HopTab shows a picker so you choose exactly which one to focus. Navigate with arrow keys, press Enter.

### Snap to Edges
Snap any window to left half, right half, quarters, or fullscreen with keyboard shortcuts.

### Multi-Monitor
Overlays appear on the screen your cursor is on. Layouts apply to the correct monitor. Works seamlessly across displays.

## Quick Start

```bash
# One-liner install
curl -sL "$(curl -s https://api.github.com/repos/royalbhati/HopTab/releases/latest \
  | grep -o '"browser_download_url": *"[^"]*"' \
  | head -1 | cut -d '"' -f 4)" -o /tmp/HopTab.zip \
  && unzip -o /tmp/HopTab.zip -d /Applications \
  && xattr -c /Applications/HopTab.app
```

Or download from [Releases](../../releases/latest), unzip, drag to `/Applications`, and run:
```bash
xattr -d com.apple.quarantine /Applications/HopTab.app
```

> **Why xattr?** HopTab is ad-hoc signed (not notarized). The command clears macOS's quarantine flag so it opens normally.

### First Launch

1. Grant **Accessibility** permission when prompted
2. Pin your apps in **Settings**
3. Press **Option+Tab** to start hopping

## Demo

![HopTab Demo](demo.gif)

## Keyboard Shortcuts

### App Switcher

| Action | Shortcut |
|--------|----------|
| Cycle forward | `Option` + `Tab` |
| Cycle backward | `Shift` + `Option` + `Tab` |
| Switch to selected | Release `Option` |
| Quit app | `Cmd` + `Q` |
| Hide app | `Cmd` + `H` |
| Minimize app | `Cmd` + `M` |
| Cancel | `Escape` |

> Configurable: Option+Tab, Control+Tab, or Option+`

### Profile Switcher

| Action | Shortcut |
|--------|----------|
| Cycle profiles | `Option` + `` ` `` |
| Cycle backward | `Shift` + `Option` + `` ` `` |
| Activate profile | Release `Option` |

### Window Picker

| Action | Shortcut |
|--------|----------|
| Navigate | `Up` / `Down` |
| Select window | `Enter` |
| Cancel | `Escape` |

## Example Setup

| Profile | Pinned Apps | Desktop | Hotkey |
|---------|------------|---------|--------|
| Coding | Xcode, Simulator, Terminal | Desktop 1 | `Ctrl+1` |
| Design | Figma, Safari, Preview | Desktop 2 | `Ctrl+2` |
| Writing | Notion, Safari, ChatGPT | Desktop 3 | `Ctrl+3` |

Swipe to Desktop 1 → Option+Tab hops between Xcode, Simulator, Terminal.
Swipe to Desktop 3 → same shortcut now hops between Notion, Safari, ChatGPT.

## Build from Source

Requires **Xcode 15+** and **macOS 14+**.

```bash
git clone https://github.com/royalbhati/HopTab.git
cd HopTab
open HopTab.xcodeproj
# Cmd+R to build and run
```

## Technical Notes

- **CGEvent tap** to intercept and swallow global shortcuts
- **AXUIElement API** to force-raise windows (fixes stubborn apps)
- **NSPanel** non-activating overlay at `.screenSaver` level
- **No App Sandbox** — required for `CGEvent.tapCreate`
- **CGSGetActiveSpace** private API for desktop-to-profile mapping

## Contributing

PRs welcome. Fork, branch, commit, push, open a PR. CI builds automatically.

## License

MIT. See [LICENSE](LICENSE).
