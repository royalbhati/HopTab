# HopTab

A lightweight macOS app switcher that lets you pin specific apps and hop between them with a single shortcut. No more cycling through 10+ open apps — just the 2-3 you actually need.

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9-orange)
![License](https://img.shields.io/badge/License-MIT-green)

## Why HopTab?

If you're the kind of person who has 10 apps open, actively use only 2–3, but refuse to close the other 7 because "what if I need them later?" — this is for you.

On macOS Cmd + Tab feels like being invited to a chaotic family reunion: Slack, Mail, Safari, Xcode, Terminal, Figma, Spotify, Notes… everyone shows up uninvited, loudly competing for attention — when all you really want is to calmly switch between your IDE and the simulator for now but you wouldnt mind browser and spotify in the background

HopTab fixes this: **pin** the apps you're actually focused on, then **Option+Tab** hops only between those. Everything else stays out of the way.

## The Productivity Boost

Most of us don't work on one thing at a time. You're coding in Xcode while checking the Simulator, glancing at Figma for the design, and Slack keeps pinging. But in any given *moment*, you're really only bouncing between 2-3 of those. The problem is Cmd+Tab doesn't know that — it treats every open app equally.

HopTab gives you **focused switching**. Pin the 2-3 apps you need right now, and Option+Tab becomes a laser-focused toggle between just those. When your context changes — say you shift from coding to writing docs — just switch your profile and your pinned apps change with you. Zero friction, zero distraction.

**Profiles + Desktop assignment** takes this further. Assign a "Coding" profile to Desktop 1 and a "Design" profile to Desktop 2. Now when you swipe between desktops, your pinned apps automatically change to match what you do there. Your workspace adapts to *you*, not the other way around.

## Features

- **Pin any app** — pick from running apps in Settings, click to pin/unpin
- **Global hotkey** — Option+Tab (default), configurable to Control+Tab or Option+`
- **Overlay switcher** — native vibrancy blur panel shows pinned apps with icons
- **Cycle forward/backward** — Shift reverses direction, Escape cancels
- **Release to activate** — let go of the modifier key to switch to the selected app
- **Profiles** — create named profiles (e.g. "Coding", "Design", "Writing") each with their own set of pinned apps
- **Desktop assignment** — bind a profile to a macOS desktop, auto-switches when you swipe to that Space
- **Persistent pins** — your pinned apps and profiles survive restarts
- **Aggressive activation** — uses Accessibility API to force-raise windows (fixes stubborn apps like Simulator)
- **Menu bar app** — lives in the menu bar, doesn't clutter your Dock

## Install

### Download

Grab the latest `.zip` from [**Releases**](../../releases/latest), unzip, and drag **HopTab.app** to `/Applications`.

```bash
# One-liner: download, unzip, and clear quarantine
curl -sL "$(curl -s https://api.github.com/repos/royalbhati/HopTab/releases/latest \
  | grep -o '"browser_download_url": *"[^"]*"' \
  | head -1 \
  | cut -d '"' -f 4)" -o /tmp/HopTab.zip \
  && unzip -o /tmp/HopTab.zip -d /Applications \
  && xattr -d com.apple.quarantine /Applications/HopTab.app
```

Or manually:

1. Download **HopTab-x.x.x.zip** from the [latest release](../../releases/latest)
2. Unzip and drag **HopTab.app** to `/Applications`
3. Clear the Gatekeeper quarantine flag:
   ```bash
   xattr -d com.apple.quarantine /Applications/HopTab.app
   ```
4. Open HopTab from `/Applications`

> **Why the xattr command?** HopTab is ad-hoc signed (not Apple notarized) so macOS shows *"Apple could not verify..."*. The command above clears the quarantine flag so it opens normally. This is safe — you can verify the source code yourself.

### Build from Source

Requires **Xcode 15+** and **macOS 14+**.

```bash
git clone https://github.com/royalbhati/HopTab.git
cd HopTab
open HopTab.xcodeproj
```

Then **Cmd+R** to build and run.

### First Launch

1. HopTab will ask for **Accessibility** permission — this is required to detect global keyboard shortcuts
2. Go to **System Settings > Privacy & Security > Accessibility** and enable HopTab
3. Open **Settings** from the menu bar icon and pin your apps
4. Press **Option+Tab** to start hopping

## Usage

| Action | Default Shortcut |
|--------|-----------------|
| Show switcher & cycle forward | Option + Tab |
| Cycle backward | Shift + Option + Tab |
| Activate selected app | Release Option |
| Cancel | Escape |

The shortcut is configurable in **Settings > Shortcut**:
- Option + Tab (default)
- Control + Tab
- Option + ` (backtick)

### Profiles

Profiles let you maintain different sets of pinned apps for different workflows. Instead of constantly pinning and unpinning apps throughout the day, create profiles and switch between them in one click.

**Setting up profiles:**

1. Open **Settings > Profiles**
2. Click **Add** to create a new profile (e.g. "Coding", "Design", "Research")
3. Switch to a profile, then go to **Pinned Apps** tab to pin the apps for that workflow
4. Switch profiles from the menu bar dropdown or from Settings

**Example setups:**

| Profile | Pinned Apps | When to use |
|---------|------------|-------------|
| Coding | Xcode, Simulator, Terminal | Building and debugging |
| Design | Figma, Safari, Preview | UI/UX work |
| Writing | Notion, Safari, ChatGPT | Docs and research |
| Comms | Slack, Mail, Calendar | Catching up on messages |

### Desktop Assignment

This is where it gets powerful. Assign a profile to a macOS desktop (Space) and it **auto-activates** when you switch to that desktop. Your pinned apps change automatically as you swipe between Spaces.

**How to set it up:**

1. Swipe to the desktop you want to assign
2. Open **Settings > Profiles**
3. Click **"Assign to this desktop"** next to the profile you want there
4. Repeat for other desktops
5. Now swipe between desktops — your profile (and pinned apps) switches automatically

**Example workflow:**

- **Desktop 1** → "Coding" profile → Xcode + Simulator + Terminal
- **Desktop 2** → "Design" profile → Figma + Safari + Preview
- **Desktop 3** → "Comms" profile → Slack + Mail + Calendar

Swipe to Desktop 1 and Option+Tab hops between Xcode, Simulator, and Terminal. Swipe to Desktop 3 and the same shortcut now hops between Slack, Mail, and Calendar. No manual switching, no reconfiguration — it just works.

> **Note:** Desktop assignment uses a macOS private API to identify Spaces. Space IDs can change after a reboot or when you add/remove desktops. If your assignments stop working, just reassign them — it takes 5 seconds.

### Some KEY decisions (pun intended)

- **CGEvent tap** (not `NSEvent.addGlobalMonitorForEvents`) — required to *swallow* the shortcut so it doesn't reach other apps
- **No App Sandbox** — `CGEvent.tapCreate(.defaultTap)` requires raw event access, incompatible with the sandbox
- **AXUIElement window raising** — `NSRunningApplication.activate()` doesn't always bring windows to front on macOS 14+; the AX `kAXRaiseAction` forces it
- **`NSPanel` overlay** — non-activating, borderless, `.screenSaver` level so it floats above everything without stealing focus
- **`CGSGetActiveSpace` private API** — used for desktop-to-profile mapping; degrades gracefully if Space IDs become stale

## Requirements

- macOS 14.0 (Sonoma) or later
- Accessibility permission (prompted on first launch)


## Releases

Releases are fully automated via GitHub Actions. To ship a new version:

```bash
git tag v0.2.0
git push origin v0.2.0
```

That's it. The [release workflow](.github/workflows/release.yml) will:

1. Extract the version from the tag
2. Stamp it into the Xcode project (`MARKETING_VERSION` + `CURRENT_PROJECT_VERSION`)
3. Build a Release configuration binary (ad-hoc signed)
4. Package `HopTab.app` into a `.zip`
5. Create a GitHub Release with the `.zip` attached and install instructions

PRs are automatically built by the [build workflow](.github/workflows/build.yml) to catch compile errors before merging.

## Contributing

Contributions welcome. Please:

1. Fork the repo
2. Create a feature branch (`git checkout -b feature/my-change`)
3. Commit your changes
4. Push and open a Pull Request

PRs are automatically built by CI to catch compile errors.

## License

MIT License. See [LICENSE](LICENSE) for details.
