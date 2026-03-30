import SwiftUI

// MARK: - Onboarding Window Controller

final class OnboardingWindowController {
    private var window: NSWindow?

    func show(appState: AppState) {
        guard window == nil else {
            window?.makeKeyAndOrderFront(nil)
            return
        }

        let view = OnboardingView(appState: appState) { [weak self] in
            self?.dismiss()
        }
        let hostingView = NSHostingView(rootView: view)

        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 640),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        w.contentView = hostingView
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.center()
        w.isReleasedWhenClosed = false
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = w
    }

    func dismiss() {
        window?.close()
        window = nil
    }
}

// MARK: - Onboarding Container

struct OnboardingView: View {
    @ObservedObject var appState: AppState
    let onComplete: () -> Void

    @State private var currentPage = 0
    @State private var appeared = false

    private let totalPages = 6

    var body: some View {
        VStack(spacing: 0) {
            // Content
            ZStack {
                if currentPage == 0 {
                    WelcomePage()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                if currentPage == 1 {
                    PinAppsPage(appState: appState)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                if currentPage == 2 {
                    ShortcutPage(appState: appState)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                if currentPage == 3 {
                    ProfilesSessionsPage()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                if currentPage == 4 {
                    LayoutsPage()
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
                if currentPage == 5 {
                    ReadyPage(appState: appState)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Bottom bar
            HStack {
                // Page dots
                HStack(spacing: 8) {
                    ForEach(0..<totalPages, id: \.self) { i in
                        Capsule()
                            .fill(i == currentPage ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: i == currentPage ? 20 : 8, height: 8)
                            .animation(.spring(response: 0.35), value: currentPage)
                    }
                }

                Spacer()

                // Skip button (pages 0-3 only, not near the end)
                if currentPage < totalPages - 2 {
                    Button("Skip") {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        onComplete()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .font(.system(size: 12))
                }

                if currentPage > 0 {
                    Button("Back") {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            currentPage -= 1
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }

                if currentPage < totalPages - 1 {
                    Button {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                            currentPage += 1
                        }
                    } label: {
                        Text(currentPage == 0 ? "Get Started" : "Next")
                            .fontWeight(.semibold)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 8)
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button {
                        UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
                        onComplete()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Let's Go")
                            Image(systemName: "arrow.right")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .fontWeight(.semibold)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 8)
                        .background(Color.accentColor)
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 28)
        }
        .padding(.top, 28)
        .frame(width: 600, height: 640)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) {
                appeared = true
            }
        }
    }
}

// MARK: - Page 1: Welcome

private struct WelcomePage: View {
    @State private var iconScale: CGFloat = 0.5
    @State private var iconOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var pillsOpacity: Double = 0
    @State private var shimmer = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                // Outer glow ring
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.accentColor.opacity(0.25), Color.accentColor.opacity(0.08), Color.clear],
                            center: .center,
                            startRadius: 20,
                            endRadius: 90
                        )
                    )
                    .frame(width: 180, height: 180)
                    .scaleEffect(shimmer ? 1.15 : 0.9)
                    .animation(.easeInOut(duration: 2.5).repeatForever(autoreverses: true), value: shimmer)

                // Inner circle
                Circle()
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 100, height: 100)
                    .scaleEffect(iconScale)

                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.accentColor, .accentColor.opacity(0.7)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .scaleEffect(iconScale)
                    .opacity(iconOpacity)
            }

            VStack(spacing: 10) {
                Text("Welcome to HopTab")
                    .font(.system(size: 28, weight: .bold))

                Text("Your workspace, one hop away.")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
            .opacity(textOpacity)

            VStack(spacing: 10) {
                FeaturePill(icon: "pin.fill", text: "Pin your most-used apps")
                FeaturePill(icon: "keyboard", text: "Switch instantly with a hotkey")
                FeaturePill(icon: "person.2.fill", text: "Workflow profiles with session memory")
                FeaturePill(icon: "rectangle.3.group", text: "Snap windows into layout templates")
            }
            .opacity(pillsOpacity)

            Spacer()
        }
        .onAppear {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.7).delay(0.1)) {
                iconScale = 1.0
                iconOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.35)) {
                textOpacity = 1.0
            }
            withAnimation(.easeOut(duration: 0.5).delay(0.55)) {
                pillsOpacity = 1.0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                shimmer = true
            }
        }
    }
}

private struct FeaturePill: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

// MARK: - Page 2: Pin Apps

private struct PinAppsPage: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "pin.fill")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Pin Your Apps")
                    .font(.system(size: 22, weight: .bold))
                Text("Pick the apps you switch between most.\nThey'll appear in your quick switcher.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ScrollView {
                LazyVStack(spacing: 2) {
                    let regularApps = appState.runningApps.filter { $0.bundleIdentifier != nil && $0.localizedName != nil && $0.activationPolicy == .regular }
                    if regularApps.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "app.dashed")
                                .font(.system(size: 24))
                                .foregroundStyle(.tertiary)
                            Text("No running apps found")
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                            Text("Open some apps and come back, or skip and pin them later in Settings.")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        ForEach(regularApps, id: \.bundleIdentifier) { app in
                            if let bundleID = app.bundleIdentifier,
                               let name = app.localizedName {
                                OnboardingAppRow(
                                    bundleID: bundleID,
                                    name: name,
                                    icon: app.icon ?? NSImage(),
                                    isPinned: appState.store.isPinned(bundleID),
                                    onToggle: {
                                        withAnimation(.spring(response: 0.3)) {
                                            appState.store.togglePin(bundleIdentifier: bundleID, displayName: name)
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: 380, maxHeight: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )

            if !appState.store.apps.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 12))
                    Text("\(appState.store.apps.count) app\(appState.store.apps.count == 1 ? "" : "s") pinned")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .scale))
            }

            Spacer()
        }
    }
}

private struct OnboardingAppRow: View {
    let bundleID: String
    let name: String
    let icon: NSImage
    let isPinned: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)
            Text(name)
                .font(.system(size: 13))
            Spacer()
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.system(size: 13))
                .foregroundColor(isPinned ? .accentColor : .secondary)
                .scaleEffect(isPinned ? 1.1 : 1.0)
                .animation(.spring(response: 0.2), value: isPinned)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(isPinned ? Color.accentColor.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }
}

// MARK: - Page 3: Your Shortcut

private struct ShortcutPage: View {
    @ObservedObject var appState: AppState
    @State private var animateKeys = false
    @State private var showRelease = false
    @State private var animStep = 0

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "keyboard")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Meet Your Shortcut")
                    .font(.system(size: 22, weight: .bold))
                Text("This is how you'll switch apps instantly.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            // Animated key demo
            VStack(spacing: 18) {
                HStack(spacing: 6) {
                    KeyCap(label: appState.appShortcutSelection.modifierName, isHighlighted: animStep >= 1)
                    Text("+")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                    KeyCap(label: appState.appShortcutSelection.keyName, isHighlighted: animStep >= 1)
                }

                VStack(spacing: 10) {
                    ShortcutStep(number: "1", text: "Hold \(appState.appShortcutSelection.modifierName) + tap \(appState.appShortcutSelection.keyName)", highlighted: animStep == 1)
                    ShortcutStep(number: "2", text: "Keep tapping to cycle through apps", highlighted: animStep == 2)
                    ShortcutStep(number: "3", text: "Release \(appState.appShortcutSelection.modifierName) to activate", highlighted: animStep == 3)
                }

                Divider()

                // Quick action hints
                HStack(spacing: 16) {
                    QuickActionHint(keys: "\u{2318}Q", label: "Quit")
                    QuickActionHint(keys: "\u{2318}H", label: "Hide")
                    QuickActionHint(keys: "\u{2318}M", label: "Minimize")
                    QuickActionHint(keys: "\u{2190}\u{2192}", label: "Snap")
                }
                .padding(.top, 2)
            }
            .padding(24)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 380)

            if !appState.permissions.isTrusted {
                VStack(spacing: 10) {
                    Text("HopTab needs Accessibility permission to detect your hotkey.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        appState.permissions.requestAccessibility()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "lock.shield")
                            Text("Enable Accessibility")
                        }
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Accessibility enabled")
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 12))
            }

            Spacer()
        }
        .onAppear { startStepAnimation() }
    }

    private func startStepAnimation() {
        animStep = 0
        withAnimation(.easeInOut(duration: 0.3).delay(0.6)) { animStep = 1 }
        withAnimation(.easeInOut(duration: 0.3).delay(1.6)) { animStep = 2 }
        withAnimation(.easeInOut(duration: 0.3).delay(2.6)) { animStep = 3 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.2) {
            withAnimation(.easeInOut(duration: 0.2)) { animStep = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                startStepAnimation()
            }
        }
    }
}

private struct QuickActionHint: View {
    let keys: String
    let label: String

    var body: some View {
        VStack(spacing: 3) {
            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
    }
}

private struct KeyCap: View {
    let label: String
    var isHighlighted: Bool = false

    var body: some View {
        Text(label)
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHighlighted ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isHighlighted ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.1), lineWidth: 1)
            )
            .foregroundColor(isHighlighted ? .accentColor : .primary)
            .scaleEffect(isHighlighted ? 1.05 : 1.0)
            .animation(.spring(response: 0.3), value: isHighlighted)
    }
}

private struct ShortcutStep: View {
    let number: String
    let text: String
    var highlighted: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Text(number)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(highlighted ? .white : .secondary)
                .frame(width: 22, height: 22)
                .background(
                    Circle()
                        .fill(highlighted ? Color.accentColor : Color.primary.opacity(0.08))
                )
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(highlighted ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: highlighted)
    }
}

// MARK: - Page 4: Profiles & Sessions

private struct ProfilesSessionsPage: View {
    @State private var activeDemo = 0
    @State private var showRestore = false

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Profiles & Sessions")
                    .font(.system(size: 22, weight: .bold))
                Text("Group apps by workflow. HopTab remembers\nwhere you left off in each one.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Visual demo: three profile cards
            HStack(spacing: 12) {
                ProfileDemoCard(
                    name: "Work",
                    apps: ["Slack", "Notion", "Chrome"],
                    icon: "briefcase",
                    isActive: activeDemo == 0
                )
                ProfileDemoCard(
                    name: "Research",
                    apps: ["Safari", "Notes", "Preview"],
                    icon: "magnifyingglass",
                    isActive: activeDemo == 1
                )
                ProfileDemoCard(
                    name: "Creative",
                    apps: ["Figma", "Music", "Photos"],
                    icon: "paintbrush",
                    isActive: activeDemo == 2
                )
            }
            .frame(maxWidth: 480)

            // Session flow
            VStack(spacing: 10) {
                SessionFlowStep(
                    icon: "tray.and.arrow.down",
                    title: "Save & Close",
                    description: "Saves window positions and quits all apps",
                    highlighted: !showRestore
                )
                Image(systemName: "arrow.down")
                    .font(.system(size: 11))
                    .foregroundStyle(.quaternary)
                SessionFlowStep(
                    icon: "arrow.counterclockwise",
                    title: "Restore Session",
                    description: "Relaunches apps with windows right where they were",
                    highlighted: showRestore
                )
            }
            .frame(maxWidth: 380)

            // Sticky note mention
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.accentColor)
                Text("Add a sticky note to any profile \u{2014} it pops up when you switch.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            Spacer()
        }
        .onAppear { startDemoAnimation() }
    }

    private func startDemoAnimation() {
        withAnimation(.easeInOut(duration: 0.5).delay(1.0)) {
            activeDemo = 1
        }
        withAnimation(.easeInOut(duration: 0.4).delay(1.5)) {
            showRestore = false
        }
        withAnimation(.easeInOut(duration: 0.5).delay(2.5)) {
            activeDemo = 2
        }
        withAnimation(.easeInOut(duration: 0.4).delay(3.5)) {
            showRestore = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            withAnimation(.easeInOut(duration: 0.5)) {
                activeDemo = 0
                showRestore = false
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                startDemoAnimation()
            }
        }
    }
}

private struct ProfileDemoCard: View {
    let name: String
    let apps: [String]
    let icon: String
    var isActive: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(isActive ? .accentColor : .secondary)

            Text(name)
                .font(.system(size: 13, weight: .semibold))

            VStack(alignment: .leading, spacing: 3) {
                ForEach(apps, id: \.self) { app in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(isActive ? Color.green : Color.gray.opacity(0.3))
                            .frame(width: 5, height: 5)
                        Text(app)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isActive ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isActive ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1.5)
        )
        .scaleEffect(isActive ? 1.02 : 0.98)
        .animation(.spring(response: 0.4), value: isActive)
    }
}

private struct SessionFlowStep: View {
    let icon: String
    let title: String
    let description: String
    var highlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(highlighted ? .accentColor : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(highlighted ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.3), value: highlighted)
    }
}

// MARK: - Page 5: Layouts & Window Snap

private struct LayoutsPage: View {
    @State private var activeLayout = 0
    @State private var snapDemo = 0

    private let layouts: [(String, [(Double, Double, Double, Double)])] = [
        ("Left + Right", [(0, 0, 0.5, 1), (0.5, 0, 0.5, 1)]),
        ("IDE (60/40)", [(0, 0, 0.6, 1), (0.6, 0, 0.4, 0.5), (0.6, 0.5, 0.4, 0.5)]),
        ("Three Columns", [(0, 0, 0.333, 1), (0.333, 0, 0.334, 1), (0.667, 0, 0.333, 1)]),
        ("Grid 2\u{00d7}2", [(0, 0, 0.5, 0.5), (0.5, 0, 0.5, 0.5), (0, 0.5, 0.5, 0.5), (0.5, 0.5, 0.5, 0.5)]),
    ]

    private let zoneColors: [Color] = [.blue, .purple, .orange, .green]

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "rectangle.3.group")
                .font(.system(size: 36))
                .foregroundStyle(Color.accentColor)

            VStack(spacing: 8) {
                Text("Layout Templates")
                    .font(.system(size: 22, weight: .bold))
                Text("Arrange windows into predefined zones.\nPick a template, assign apps, and go.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            // Animated layout carousel
            VStack(spacing: 12) {
                // Layout preview
                ZStack {
                    let current = layouts[activeLayout]
                    ForEach(Array(current.1.enumerated()), id: \.offset) { idx, zone in
                        RoundedRectangle(cornerRadius: 4)
                            .fill(zoneColors[idx % zoneColors.count].opacity(0.15))
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(zoneColors[idx % zoneColors.count].opacity(0.4), lineWidth: 1.5)
                            )
                            .frame(
                                width: 260 * zone.2 - 4,
                                height: 140 * zone.3 - 4
                            )
                            .position(
                                x: 260 * (zone.0 + zone.2 / 2),
                                y: 140 * (zone.1 + zone.3 / 2)
                            )
                    }
                }
                .frame(width: 260, height: 140)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .animation(.spring(response: 0.5, dampingFraction: 0.8), value: activeLayout)

                Text(layouts[activeLayout].0)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .animation(.none, value: activeLayout)

                // Dot indicators
                HStack(spacing: 6) {
                    ForEach(0..<layouts.count, id: \.self) { i in
                        Circle()
                            .fill(i == activeLayout ? Color.accentColor : Color.secondary.opacity(0.25))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .padding(20)
            .background(Color.primary.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 340)

            // Arrow key snap hint
            VStack(spacing: 10) {
                HStack(spacing: 20) {
                    SnapHint(icon: "arrow.left", label: "Snap Left", active: snapDemo == 1)
                    SnapHint(icon: "arrow.up", label: "Fullscreen", active: snapDemo == 2)
                    SnapHint(icon: "arrow.right", label: "Snap Right", active: snapDemo == 3)
                }

                Text("Use arrow keys while the switcher is open to snap windows")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .onAppear {
            startLayoutAnimation()
            startSnapAnimation()
        }
    }

    private func startLayoutAnimation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { activeLayout = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation { activeLayout = 2 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            withAnimation { activeLayout = 3 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) {
            withAnimation { activeLayout = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                startLayoutAnimation()
            }
        }
    }

    private func startSnapAnimation() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeInOut(duration: 0.3)) { snapDemo = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            withAnimation(.easeInOut(duration: 0.3)) { snapDemo = 2 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(.easeInOut(duration: 0.3)) { snapDemo = 3 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) {
            withAnimation(.easeInOut(duration: 0.2)) { snapDemo = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                startSnapAnimation()
            }
        }
    }
}

private struct SnapHint: View {
    let icon: String
    let label: String
    var active: Bool

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? Color.accentColor : .secondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(active ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
                )
                .scaleEffect(active ? 1.1 : 1.0)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(active ? .accentColor : .gray)
        }
        .animation(.spring(response: 0.3), value: active)
    }
}

// MARK: - Page 6: Ready

private struct ReadyPage: View {
    @ObservedObject var appState: AppState
    @State private var checkmarks: [Bool] = [false, false, false, false, false]

    var body: some View {
        VStack(spacing: 18) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.1))
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.green)
            }

            VStack(spacing: 6) {
                Text("You're All Set")
                    .font(.system(size: 22, weight: .bold))
                Text("HopTab is ready. Here's what you can do:")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
                TipRow(
                    icon: "keyboard",
                    title: appState.appShortcutSelection.displayName,
                    subtitle: "Hold modifier, tap key to cycle, release to switch",
                    checked: checkmarks[0]
                )
                TipRow(
                    icon: "person.2.fill",
                    title: "Workflow Profiles",
                    subtitle: "Create separate app sets for each workflow",
                    checked: checkmarks[1]
                )
                TipRow(
                    icon: "tray.and.arrow.down",
                    title: "Save & Close / Restore",
                    subtitle: "Quit a profile's apps, bring them back exactly",
                    checked: checkmarks[2]
                )
                TipRow(
                    icon: "rectangle.3.group",
                    title: "Layout Templates",
                    subtitle: "Snap windows into zones like Left+Right, IDE, Grid",
                    checked: checkmarks[3]
                )
                TipRow(
                    icon: "note.text",
                    title: "Sticky Notes",
                    subtitle: "Leave a note that shows when switching profiles",
                    checked: checkmarks[4]
                )
            }
            .padding(16)
            .background(Color.primary.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 440)

            HStack(spacing: 6) {
                Image(systemName: "arrow.2.squarepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("Find HopTab in your menu bar")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .onAppear {
            for i in 0..<5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.2 + 0.3) {
                    withAnimation(.spring(response: 0.4)) {
                        checkmarks[i] = true
                    }
                }
            }
        }
    }
}

private struct TipRow: View {
    let icon: String
    let title: String
    let subtitle: String
    var checked: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                if checked {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.system(size: 18))
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Image(systemName: icon)
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 16))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .frame(width: 24, height: 24)
            .animation(.spring(response: 0.3), value: checked)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
