import AppKit
import SwiftUI

// MARK: - Onboarding Window Controller

final class OnboardingWindowController {
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(appState: AppState) {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let view = OnboardingView(appState: appState) { [weak self] in
            self?.dismiss()
        }
        let hostingView = NSHostingView(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 720),
            // Resizable: at large accessibility text sizes a fixed 600×640 box
            // clipped its own content with no way to reach it.
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        w.contentView = hostingView
        w.contentMinSize = NSSize(width: 520, height: 460)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.title = "Set Up HopTab"
        w.isMovableByWindowBackground = true
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        self.window = w

        // Closing the window (red traffic light) counts as Skip — otherwise
        // onboarding re-opens on every launch forever.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
            self?.teardown()
        }
    }

    func dismiss() {
        window?.close()
        teardown()
    }

    private func teardown() {
        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
            self.closeObserver = nil
        }
        window = nil
    }
}

// MARK: - Steps

/// Three steps. The grant nothing works without; a real workspace from the
/// apps already running; then a guided tour where every HopTab key is
/// pressed for real and ticked off as it happens.
private enum OnboardingStep: Int, CaseIterable, Identifiable {
    /// The Accessibility grant — nothing below works without it.
    case access
    /// A real workspace from what's running.
    case workspace
    /// Press each key once; HopTab watches and ticks them off.
    case tour

    var id: Int { rawValue }
}

// MARK: - Progress signals

/// Counters the app bumps when a feature is actually used, so the tour can
/// tick a step off because the user performed it, not because they read it.
enum OnboardingProgress {
    enum Event: String, CaseIterable {
        case allAppsSwitcher, workspaceSwitcher, workspacePicker, commandPalette, snap
    }

    static let didChange = Notification.Name("com.hoptab.onboardingProgress")

    static func bump(_ event: Event) {
        let key = storageKey(event)
        UserDefaults.standard.set(UserDefaults.standard.integer(forKey: key) + 1, forKey: key)
        NotificationCenter.default.post(name: didChange, object: event)
    }

    static func count(_ event: Event) -> Int {
        UserDefaults.standard.integer(forKey: storageKey(event))
    }

    private static func storageKey(_ event: Event) -> String { "onboarding.count.\(event.rawValue)" }
}

// MARK: - Onboarding Container

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    /// Observed separately: `AppState` forwards its store's changes but not the
    /// permission service's, and several steps are driven by `isTrusted`.
    @ObservedObject private var permissions: PermissionsService
    let onComplete: () -> Void

    init(appState: AppState, onComplete: @escaping () -> Void) {
        _appState = ObservedObject(wrappedValue: appState)
        _permissions = ObservedObject(wrappedValue: appState.permissions)
        self.onComplete = onComplete
    }

    @State private var step: OnboardingStep = .access
    @State private var goingBack = false
    @State private var appeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var steps: [OnboardingStep] { OnboardingStep.allCases }
    private var stepIndex: Int { steps.firstIndex(of: step) ?? 0 }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ScrollView(.vertical) {
                    pageContent
                        .padding(.horizontal, HopSpacing.xxl)
                        .padding(.vertical, HopSpacing.lg)
                        .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
            }

            bottomBar
                .padding(.horizontal, HopSpacing.xxl)
                .padding(.top, HopSpacing.md)
                .padding(.bottom, HopSpacing.xl)
        }
        .padding(.top, HopSpacing.xl)
        .frame(minWidth: 520, minHeight: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(HopMotion.panel) { appeared = true }
        }
        .onDisappear {
            // Closing the window with the traffic-light button is equivalent to
            // Skip — otherwise onboarding re-triggers on every launch forever.
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }
    }

    // MARK: Pages

    @ViewBuilder
    private var pageContent: some View {
        ZStack {
            if step == .access {
                AccessibilityPage(permissions: permissions)
                    .transition(pageTransition)
            }
            if step == .workspace {
                PinAppsPage(appState: appState)
                    .transition(pageTransition)
            }
            if step == .tour {
                TourPage(
                    appState: appState,
                    permissions: permissions,
                    onNeedsAccess: { go(to: .access, backwards: true) }
                )
                .transition(pageTransition)
            }
        }
    }

    /// Slide in the direction of travel — but a plain cross-fade under
    /// Reduce Motion, and driven by `HopMotion`, which collapses to near-zero
    /// duration there.
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        let incoming: Edge = goingBack ? .leading : .trailing
        let outgoing: Edge = goingBack ? .trailing : .leading
        return .asymmetric(
            insertion: .move(edge: incoming).combined(with: .opacity),
            removal: .move(edge: outgoing).combined(with: .opacity)
        )
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: HopSpacing.md) {
            stepDots

            Spacer(minLength: HopSpacing.md)

            if step != .tour {
                Button("Skip Setup") { finish() }
                    .buttonStyle(.link)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Close onboarding and use HopTab right away")
            }

            if step != .access {
                Button("Back") { back() }
            }

            Button(primaryTitle) { primaryAction() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private var stepDots: some View {
        HStack(spacing: HopSpacing.sm) {
            ForEach(steps) { s in
                Capsule()
                    .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: s == step ? 20 : 8, height: 8)
                    .animation(HopMotion.snappy, value: step)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(stepIndex + 1) of \(steps.count)")
    }

    private var primaryTitle: String {
        switch step {
        case .access: return permissions.isTrusted ? "Continue" : "Continue Anyway"
        case .workspace: return "Next: Try the Keys"
        case .tour: return "Finish"
        }
    }

    // MARK: Navigation

    private func primaryAction() {
        if step == .tour {
            finish()
            return
        }
        let next = steps.firstIndex(of: step).map { $0 + 1 } ?? 0
        guard next < steps.count else {
            finish()
            return
        }
        go(to: steps[next])
    }

    private func back() {
        let prev = (steps.firstIndex(of: step) ?? 0) - 1
        guard prev >= 0 else { return }
        go(to: steps[prev], backwards: true)
    }

    private func go(to target: OnboardingStep, backwards: Bool = false) {
        goingBack = backwards
        withAnimation(HopMotion.snappy) { step = target }
    }

    private func finish() {
        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        onComplete()
    }
}

// MARK: - Shared pieces

/// Calm page mark: a single SF Symbol on a tinted plate. Sized by padding, not
/// a fixed frame, so it grows with accessibility text sizes instead of clipping.
private struct PageMark: View {
    let symbol: String
    var tint: Color = .accentColor

    var body: some View {
        Image(systemName: symbol)
            .font(.largeTitle)
            .imageScale(.large)
            .foregroundStyle(tint)
            .padding(HopSpacing.lg)
            .background(
                RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                    .fill(tint.opacity(0.10))
            )
            .accessibilityHidden(true)
    }
}

private struct PageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: HopSpacing.sm) {
            Text(title)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.hopSubheading)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Status line with a semantic color. Never color-only — the icon and the text
/// both carry the meaning.
private struct StatusLine: View {
    let symbol: String
    let text: String
    var tint: Color = HopColor.success

    var body: some View {
        HStack(spacing: HopSpacing.sm) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(text)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.hopCaption)
    }
}


// MARK: - Step 1: Accessibility

private struct AccessibilityPage: View {
    @ObservedObject var permissions: PermissionsService
    @State private var didRequest = false

    var body: some View {
        VStack(spacing: HopSpacing.xl) {
            PageMark(
                symbol: permissions.isTrusted ? "lock.open.fill" : "lock.shield",
                tint: permissions.isTrusted ? HopColor.success : Color.accentColor
            )

            PageTitle(
                title: permissions.isTrusted ? "Accessibility Is On" : "Let HopTab See Your Hotkey",
                subtitle: permissions.isTrusted
                    ? "HopTab can watch for your hotkey and move windows. Nothing leaves your Mac."
                    : "macOS gates keyboard shortcuts and window moves behind Accessibility. Without it, the hotkey does nothing."
            )

            if permissions.isTrusted {
                VStack(spacing: HopSpacing.sm) {
                    StatusLine(symbol: "checkmark.circle.fill", text: "Permission granted \u{2014} your hotkey is live.")
                }
                .transition(.opacity)
            } else {
                VStack(spacing: HopSpacing.lg) {
                    Button(permissions.canShowSystemPrompt ? "Grant Access" : "Open System Settings") {
                        didRequest = true
                        permissions.requestAccessibility()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    if !didRequest {
                        // The system dialog is a one-shot. Say which of the two
                        // worlds we're in before the click, not after it.
                        Text(permissions.canShowSystemPrompt
                             ? "macOS shows its permission dialog once per install. Choose Open System Settings in it, then switch HopTab on."
                             : "That one-time dialog has already been used, so it can't appear again. Switch HopTab on under Privacy & Security \u{203A} Accessibility.")
                            .font(.hopFootnote)
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if didRequest || permissions.hasPromptedBefore {
                        HStack(spacing: HopSpacing.sm) {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityHidden(true)
                            Text("Waiting for permission\u{2026} this page updates the moment you flip the switch.")
                                .font(.hopCaption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 420)
            }

            Text("HopTab uses Accessibility only to read its own shortcut and to move and resize windows.")
                .font(.hopFootnote)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            FeatureStrip()
        }
        .animation(HopMotion.emphasis, value: permissions.isTrusted)
        .onAppear {
            permissions.refresh()
            permissions.startPolling()
        }
    }
}

/// Three things HopTab does, on the first screen, so the permission ask has
/// a reason attached. Each one is pressed for real on the last step.
private struct FeatureStrip: View {
    private let items: [(symbol: String, title: String, detail: String)] = [
        ("square.stack.3d.up.fill", "Workspaces", "Named sets of apps. Switch one, the rest get out of the way."),
        ("rectangle.on.rectangle", "A better \u{2318}Tab", "Your workspace first, everything else after. Pin with one key."),
        ("magnifyingglass", "\u{2325}K palette", "Apps, Chrome tabs, projects, workspaces and actions in one search."),
    ]

    var body: some View {
        HStack(alignment: .top, spacing: HopSpacing.md) {
            ForEach(items, id: \.title) { item in
                VStack(alignment: .leading, spacing: HopSpacing.xs) {
                    Image(systemName: item.symbol)
                        .font(.title3)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                    Text(item.title)
                        .font(.hopCaption.weight(.semibold))
                    Text(item.detail)
                        .font(.hopFootnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(HopSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
            }
        }
        .frame(maxWidth: 520)
        .padding(.top, HopSpacing.sm)
    }
}

// MARK: - Step 2: A workspace from what's already running

/// One row's worth of data, snapshotted so the list doesn't re-query
/// `NSWorkspace` on every redraw.
private struct OnboardingCandidate: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage
    var id: String { bundleID }
}

private struct PinAppsPage: View {
    @ObservedObject var appState: AppState

    /// How many running apps get pre-selected on a fresh install.
    private static let suggestionLimit = 5

    @State private var candidates: [OnboardingCandidate] = []
    @State private var seeded = false
    @State private var profileName = ""
    @State private var userNamedIt = false
    @FocusState private var nameFocused: Bool

    private var pinnedCount: Int { appState.store.apps.count }

    var body: some View {
        VStack(spacing: HopSpacing.xl) {
            PageMark(symbol: "square.stack.3d.up.fill")

            PageTitle(
                title: "Your First Workspace",
                subtitle: candidates.isEmpty
                    ? "A workspace is a named set of apps. Nothing is running right now, so there's nothing to add yet."
                    : "Built from the apps you're already using. Untick anything that doesn't belong, then try the key below."
            )

            if !candidates.isEmpty {
                VStack(alignment: .leading, spacing: HopSpacing.sm) {
                    Text("Workspace name")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                    TextField("Workspace name", text: $profileName)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .onSubmit {
                            userNamedIt = true
                            commitName()
                        }
                        .onChange(of: nameFocused) { wasFocused, isFocused in
                            if wasFocused && !isFocused {
                                userNamedIt = true
                                commitName()
                            }
                        }
                        .accessibilityLabel("Workspace name")
                }
                .frame(maxWidth: 420)
            }

            if candidates.isEmpty {
                VStack(spacing: HopSpacing.sm) {
                    Image(systemName: "app.dashed")
                        .font(.title)
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("No other apps are running")
                        .font(.hopSubheading)
                    Text("Open the apps you work in and come back, or add them any time from Settings \u{203A} Apps.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: 380)
                .padding(.vertical, HopSpacing.lg)
            } else {
                VStack(spacing: HopSpacing.sm) {
                    StatusLine(
                        symbol: pinnedCount > 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                        text: pinnedCount > 0
                            ? "\(pinnedCount) app\(pinnedCount == 1 ? "" : "s") pinned \u{2014} saved as you go."
                            : "Nothing pinned yet \u{2014} pick at least one app to hop between.",
                        tint: pinnedCount > 0 ? HopColor.success : HopColor.warning
                    )

                    VStack(spacing: 2) {
                        ForEach(candidates) { candidate in
                            OnboardingAppRow(
                                candidate: candidate,
                                isPinned: appState.store.isPinned(candidate.bundleID),
                                onToggle: { toggle(candidate) }
                            )
                        }
                    }
                    .padding(.vertical, HopSpacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                            .fill(Color.primary.opacity(0.03))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
                .frame(maxWidth: 420)
            }

            Toggle(isOn: Binding(
                get: { appState.replaceCommandTab },
                set: { appState.replaceCommandTab = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use \u{2318}Tab for all apps")
                        .font(.hopSubheading.weight(.medium))
                    Text("Replaces the macOS switcher: this workspace\u{2019}s apps first, everything else after. \(appState.appShortcutSelection.modifierName) + \(appState.appShortcutSelection.keyName) cycles only the workspace.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .padding(HopSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                    .fill(Color.primary.opacity(0.03))
            )
            .frame(maxWidth: 420)
        }
        .onAppear {
            if UserDefaults.standard.object(forKey: "replaceCommandTab") == nil {
                appState.replaceCommandTab = true
            }
            seedIfNeeded()
        }
        .onChange(of: appState.runningApps.count) { _, _ in
            candidates = Self.gatherCandidates(from: appState.runningApps)
        }
        .onChange(of: appState.store.apps) { _, _ in
            if !userNamedIt { profileName = suggestedName }
        }
        .onDisappear { commitName() }
    }

    // MARK: Actions

    private func toggle(_ candidate: OnboardingCandidate) {
        withAnimation(HopMotion.snappy) {
            appState.store.togglePin(bundleIdentifier: candidate.bundleID, displayName: candidate.name)
        }
    }

    /// Pre-pin what the user is already running, so the default state is useful
    /// and they un-pick rather than start from an empty list. Only ever seeds an
    /// empty profile — re-running onboarding never overwrites existing pins.
    private func seedIfNeeded() {
        guard !seeded else { return }
        seeded = true

        appState.refreshRunningApps()
        candidates = Self.gatherCandidates(from: appState.runningApps)

        if appState.store.apps.isEmpty {
            for candidate in candidates.prefix(Self.suggestionLimit) {
                appState.store.add(
                    PinnedApp(bundleIdentifier: candidate.bundleID, displayName: candidate.name, sortOrder: 0)
                )
            }
        }

        let existing = appState.store.activeProfile?.name ?? ""
        if existing.isEmpty || existing == "Default" {
            profileName = suggestedName
        } else {
            profileName = existing
            userNamedIt = true
        }
    }

    /// Name the profile after what's in it, until the user names it themselves.
    private var suggestedName: String {
        let names = appState.store.apps.prefix(2).map { $0.displayName }
        guard !names.isEmpty else { return "Main" }
        return names.joined(separator: " + ")
    }

    private func commitName() {
        guard let profile = appState.store.activeProfile else { return }
        let trimmed = profileName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != profile.name else { return }
        appState.store.renameProfile(id: profile.id, to: trimmed)
    }

    // MARK: Candidates

    private static func gatherCandidates(from running: [NSRunningApplication]) -> [OnboardingCandidate] {
        let ownBundle = Bundle.main.bundleIdentifier
        // Finder is always running and is never what someone pins first.
        let excluded: Set<String> = ["com.apple.finder"]
        let zOrder = frontToBackRanks()

        var seen = Set<String>()
        var result: [(rank: Int, candidate: OnboardingCandidate)] = []

        for app in running {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier, !bundleID.isEmpty,
                  let name = app.localizedName, !name.isEmpty,
                  bundleID != ownBundle,
                  !excluded.contains(bundleID),
                  !seen.contains(bundleID)
            else { continue }
            seen.insert(bundleID)
            result.append((
                zOrder[app.processIdentifier] ?? Int.max,
                OnboardingCandidate(bundleID: bundleID, name: name, icon: app.icon ?? NSImage())
            ))
        }

        return result
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                return lhs.candidate.name.localizedStandardCompare(rhs.candidate.name) == .orderedAscending
            }
            .map { $0.candidate }
    }

    /// Front-to-back window order as a recency proxy: the app whose window is
    /// on top was used most recently. Needs no extra permission — only the
    /// owning PID and layer are read, never window titles.
    private static func frontToBackRanks() -> [pid_t: Int] {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [:] }

        var ranks: [pid_t: Int] = [:]
        var next = 0
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  ranks[pid] == nil
            else { continue }
            ranks[pid] = next
            next += 1
        }
        return ranks
    }
}

private struct OnboardingAppRow: View {
    let candidate: OnboardingCandidate
    let isPinned: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: HopSpacing.md) {
                Image(nsImage: candidate.icon)
                    .resizable()
                    .frame(width: 26, height: 26)
                    .accessibilityHidden(true)
                Text(candidate.name)
                    .font(.hopSubheading)
                    .foregroundStyle(.primary)
                Spacer(minLength: HopSpacing.sm)
                Image(systemName: isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(isPinned ? Color.accentColor : .secondary)
                    .scaleEffect(isPinned ? 1.1 : 1.0)
                    .animation(HopMotion.emphasis, value: isPinned)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, HopSpacing.md)
            .padding(.vertical, HopSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isPinned ? Color.accentColor.opacity(0.08) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(candidate.name)
        .accessibilityValue(isPinned ? "Pinned" : "Not pinned")
        .accessibilityHint(isPinned ? "Removes this app from the switcher" : "Adds this app to the switcher")
        .accessibilityAddTraits(isPinned ? [.isSelected] : [])
    }
}

// MARK: - Step 3: the tour

/// One thing to press per row. The row is "waiting" until the app reports
/// the gesture happened, then it is done for good. Nothing here simulates
/// anything: the switcher, palette and snap really open over this window.
private struct TourTask: Identifiable {
    enum Requirement {
        case none
        case accessibility
        case secondWorkspace
    }

    let id: String
    let event: OnboardingProgress.Event
    let symbol: String
    let title: String
    let keys: [String]
    let instruction: String
    let doneText: String
    let requirement: Requirement
}

private struct TourPage: View {
    @ObservedObject var appState: AppState
    @ObservedObject var permissions: PermissionsService
    let onNeedsAccess: () -> Void

    /// Counts at the moment the page appeared. A step is done when its
    /// counter has moved since, so earlier sessions don't pre-tick the tour.
    @State private var baseline: [OnboardingProgress.Event: Int] = [:]
    @State private var completed: Set<OnboardingProgress.Event> = []

    private var tasks: [TourTask] {
        var out: [TourTask] = []
        let modifier = appState.appShortcutSelection.modifierName
        let key = appState.appShortcutSelection.keyName
        let workspaceKeys = [KeyGlyph.modifier(modifier), key]

        if appState.replaceCommandTab {
            out.append(TourTask(
                id: "all",
                event: .allAppsSwitcher,
                symbol: "rectangle.on.rectangle",
                title: "Switch between apps",
                keys: ["\u{2318}", "Tab"],
                instruction: "Hold \u{2318}, tap Tab, let go. Your workspace\u{2019}s apps come first, everything else after. While it\u{2019}s open, P pins the highlighted app to this workspace.",
                doneText: "That\u{2019}s your new \u{2318}Tab.",
                requirement: .accessibility
            ))
            out.append(TourTask(
                id: "workspace",
                event: .workspaceSwitcher,
                symbol: "square.stack.3d.up",
                title: "Cycle just this workspace",
                keys: workspaceKeys,
                instruction: "Hold \(modifier), tap \(key). Only the apps you pinned appear, so you never scroll past Slack to reach your editor.",
                doneText: "Pinned apps only. Nothing else gets in the way.",
                requirement: .accessibility
            ))
        } else {
            out.append(TourTask(
                id: "workspace",
                event: .workspaceSwitcher,
                symbol: "square.stack.3d.up",
                title: "Switch between your apps",
                keys: workspaceKeys,
                instruction: "Hold \(modifier), tap \(key), let go. Only the apps you pinned appear. P pins the highlighted app, \u{232B} unpins it.",
                doneText: "That\u{2019}s a hop.",
                requirement: .accessibility
            ))
        }

        out.append(TourTask(
            id: "picker",
            event: .workspacePicker,
            symbol: "arrow.left.arrow.right.square",
            title: "Jump to another workspace",
            keys: [KeyGlyph.modifier(appState.profileShortcutModifierName), appState.profileShortcutKeyName],
            instruction: "Hold \(appState.profileShortcutModifierName), tap \(appState.profileShortcutKeyName). Switching hides the old workspace\u{2019}s windows and brings the new one\u{2019}s back where they were.",
            doneText: "Workspaces swap in one key.",
            requirement: .secondWorkspace
        ))

        if appState.commandPaletteEnabled {
            let palette = appState.effectiveCommandPaletteShortcut
            out.append(TourTask(
                id: "palette",
                event: .commandPalette,
                symbol: "magnifyingglass",
                title: "Find anything",
                keys: [KeyGlyph.modifier(palette.modifierName), palette.keyName],
                instruction: "Press \(palette.displayName), type a few letters of an app, a Chrome tab, a project or a workspace, then Enter. Esc closes it.",
                doneText: "Apps, tabs, history, projects, actions: one box.",
                requirement: .accessibility
            ))
        }

        if let left = SnapShortcutConfig.current.bindings[.left] {
            out.append(TourTask(
                id: "snap",
                event: .snap,
                symbol: "rectangle.lefthalf.inset.filled",
                title: "Snap a window",
                keys: [KeyGlyph.modifier(left.modifierName), left.keyName],
                instruction: "Click any window, then press \(left.displayName) to fill the left half. Every other half, quarter and third has a key in Settings \u{203A} Shortcuts.",
                doneText: "Snapped. Drag a window to a screen edge for the same thing.",
                requirement: .accessibility
            ))
        }
        return out
    }

    private var doneCount: Int { tasks.filter { completed.contains($0.event) }.count }
    private var hasSecondWorkspace: Bool { appState.store.profiles.count > 1 }

    var body: some View {
        VStack(spacing: HopSpacing.xl) {
            PageMark(symbol: doneCount == tasks.count ? "checkmark.seal.fill" : "hand.tap.fill",
                     tint: doneCount == tasks.count ? HopColor.success : Color.accentColor)

            PageTitle(
                title: doneCount == tasks.count ? "You Know HopTab" : "Try Each Key Once",
                subtitle: doneCount == tasks.count
                    ? "Every shortcut is yours to change under Settings \u{203A} Shortcuts. Finish to close this window."
                    : "This window stays put. Press each key for real and the row ticks itself off."
            )

            if !permissions.isTrusted {
                HStack(alignment: .firstTextBaseline, spacing: HopSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(HopColor.warning)
                        .accessibilityHidden(true)
                    Text("Accessibility isn\u{2019}t granted, so none of these keys work yet.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Fix") { onNeedsAccess() }
                        .controlSize(.small)
                }
                .padding(HopSpacing.md)
                .background(
                    RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                        .fill(HopColor.tint(HopColor.warning))
                )
                .frame(maxWidth: 460)
            } else if appState.hotkeyStatus == .failed {
                StatusLine(symbol: "exclamationmark.triangle.fill",
                           text: "HopTab couldn\u{2019}t install its key listener. Quit and reopen HopTab.",
                           tint: HopColor.warning)
            }

            VStack(spacing: HopSpacing.sm) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    TourRow(
                        task: task,
                        index: index + 1,
                        isDone: completed.contains(task.event),
                        isCurrent: !completed.contains(task.event)
                            && tasks.first(where: { !completed.contains($0.event) })?.id == task.id,
                        blocker: blocker(for: task),
                        onAddWorkspace: addSecondWorkspace
                    )
                }
            }
            .frame(maxWidth: 460)

            ProgressView(value: Double(doneCount), total: Double(max(tasks.count, 1)))
                .progressViewStyle(.linear)
                .frame(maxWidth: 460)
                .accessibilityLabel("\(doneCount) of \(tasks.count) tried")
                .animation(HopMotion.snappy, value: doneCount)
        }
        .animation(HopMotion.emphasis, value: completed)
        .onAppear {
            appState.setTourKeyCapture(true)
            permissions.refresh()
            if !permissions.isTrusted { permissions.startPolling() }
            if baseline.isEmpty {
                for event in OnboardingProgress.Event.allCases {
                    baseline[event] = OnboardingProgress.count(event)
                }
            }
        }
        .onDisappear { appState.setTourKeyCapture(false) }
        .onReceive(NotificationCenter.default.publisher(for: OnboardingProgress.didChange)) { note in
            guard let event = note.object as? OnboardingProgress.Event,
                  OnboardingProgress.count(event) > (baseline[event] ?? 0)
            else { return }
            completed.insert(event)
        }
    }

    private func blocker(for task: TourTask) -> String? {
        switch task.requirement {
        case .none: return nil
        case .accessibility: return permissions.isTrusted ? nil : "Needs Accessibility"
        case .secondWorkspace:
            if !permissions.isTrusted { return "Needs Accessibility" }
            return hasSecondWorkspace ? nil : "Needs a second workspace"
        }
    }

    /// The picker needs somewhere to go. Make an empty second workspace the
    /// user can fill later; it is just a named list.
    private func addSecondWorkspace() {
        guard appState.store.canAddProfile else { return }
        appState.store.addProfile(name: "Workspace 2")
    }
}

/// Keycap glyphs for modifier names coming out of `ShortcutSelection`.
private enum KeyGlyph {
    static func modifier(_ name: String) -> String {
        name.split(separator: "+")
            .map { part -> String in
                switch part.trimmingCharacters(in: .whitespaces) {
                case "Option": return "\u{2325}"
                case "Control": return "\u{2303}"
                case "Command": return "\u{2318}"
                case "Shift": return "\u{21E7}"
                case "fn", "Fn", "Globe": return "\u{1F310}"
                case let other: return other
                }
            }
            .joined()
    }
}

private struct TourRow: View {
    let task: TourTask
    let index: Int
    let isDone: Bool
    let isCurrent: Bool
    let blocker: String?
    let onAddWorkspace: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: HopSpacing.md) {
            ZStack {
                Circle()
                    .fill(isDone ? HopColor.success : (isCurrent ? Color.accentColor : Color.secondary.opacity(0.2)))
                    .frame(width: 24, height: 24)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(index)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCurrent ? Color.white : Color.secondary)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: HopSpacing.xs) {
                HStack(spacing: HopSpacing.sm) {
                    Image(systemName: task.symbol)
                        .foregroundStyle(isDone ? HopColor.success : Color.accentColor)
                        .accessibilityHidden(true)
                    Text(task.title)
                        .font(.hopSubheading.weight(.semibold))
                    Spacer(minLength: HopSpacing.sm)
                    HStack(spacing: 3) {
                        ForEach(Array(task.keys.enumerated()), id: \.offset) { _, k in
                            MiniKeyCap(label: k, isHighlighted: isCurrent && !isDone && blocker == nil)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Shortcut: \(task.keys.joined(separator: " "))")
                }

                Text(isDone ? task.doneText : task.instruction)
                    .font(.hopCaption)
                    .foregroundStyle(isDone ? HopColor.success : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if !isDone, let blocker {
                    HStack(spacing: HopSpacing.sm) {
                        Image(systemName: "info.circle")
                            .accessibilityHidden(true)
                        Text(blocker)
                        if task.requirement == .secondWorkspace {
                            Button("Add one") { onAddWorkspace() }
                                .controlSize(.mini)
                        }
                    }
                    .font(.hopFootnote)
                    .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(HopSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                .fill(isCurrent && !isDone ? HopColor.tint(Color.accentColor) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                .stroke(isCurrent && !isDone ? HopColor.edge(Color.accentColor) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityValue(isDone ? "Done" : (blocker ?? "Not yet tried"))
    }
}

private struct MiniKeyCap: View {
    let label: String
    let isHighlighted: Bool

    var body: some View {
        Text(label)
            .font(.system(.caption, design: .rounded).weight(.semibold))
            .padding(.horizontal, HopSpacing.sm)
            .padding(.vertical, HopSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                    .stroke(isHighlighted ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
            )
            .foregroundStyle(isHighlighted ? Color.accentColor : Color.primary)
    }
}
