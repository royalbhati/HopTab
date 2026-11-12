import AppKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Shortcuts Section (switcher family)

struct ShortcutsSection: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        switcherShortcutSection
        profileShortcutSection
        commandPaletteSection
        howItWorksSection
    }

    @ViewBuilder
    private var switcherShortcutSection: some View {
        Section {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: HopSpacing.sm)], spacing: HopSpacing.sm) {
                ForEach(ShortcutPreset.allCases.filter { $0 != .commandTab }) { preset in
                    presetCard(preset)
                }
                customCard
            }

            if appState.shortcutsConflict {
                conflictBanner
            }

            // Recovery UI — surface Retry / Open Settings when the hotkey is degraded.
            if appState.hotkeyStatus != .running {
                hotkeyStatusRow
            }

            if appState.isSecureInputActive {
                HopBanner(
                    icon: "lock.fill",
                    tone: HopColor.warning,
                    title: "Shortcuts are paused right now",
                    detail: "A password field has keyboard security on. macOS blocks every global shortcut until you click out of it."
                ) {
                    EmptyView()
                }
            }
        } header: {
            HStack {
                Text("Workspace Apps Switcher")
                Spacer()
                hotkeyStatusBadge
            }
        } footer: {
            Text("Cycles only the current workspace\u{2019}s apps. Hold the modifier, tap the key, release to switch. Shift reverses the cycle, so this shortcut can never include Shift itself.")
        }

        Section {
            Toggle(isOn: $appState.replaceCommandTab) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Replace \u{2318}Tab with HopTab")
                    Text("Every running app, your workspace\u{2019}s first. Press P to pin the highlighted app here, 1\u{2013}9 to pin it to any workspace, N for a new workspace with it.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("All Apps Switcher")
        } footer: {
            Text("Off means \u{2318}Tab stays the macOS switcher. Pinning keys also work in the workspace switcher above.")
        }

        Section {
            Toggle(isOn: $appState.askWhichWindow) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ask which window after switching")
                    Text("When the app you switch to has several windows on this Space, list them so you can pick one with \u{2191}\u{2193} and Return.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Windows")
        } footer: {
            Text("Off means switching goes straight to the app\u{2019}s last window. Either way, press Space on a highlighted app in the switcher to see its windows.")
        }
    }

    private func presetCard(_ preset: ShortcutPreset) -> some View {
        let isSelected = appState.selectedPreset == preset
        return Button { appState.selectPreset(preset) } label: {
            HStack {
                Text(preset.displayName)
                    .font(isSelected ? .hopSubheading.weight(.semibold) : .hopSubheading)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, HopSpacing.sm + 2)
            .padding(.vertical, HopSpacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                            .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var customCard: some View {
        let isSelected = appState.isCustomAppShortcut
        return VStack(alignment: .leading, spacing: HopSpacing.xs) {
            Button { appState.selectCustomMode() } label: {
                HStack {
                    Text("Custom")
                        .font(isSelected ? .hopSubheading.weight(.semibold) : .hopSubheading)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, HopSpacing.sm + 2)
                .padding(.vertical, HopSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])

            if isSelected {
                // Switcher family — Shift must be stripped at record time.
                ShortcutRecorderView(shortcut: $appState.customAppShortcut, mode: .shiftInsensitive)
                    .padding(.horizontal, HopSpacing.xs)
            }
        }
    }

    private var profileShortcutSection: some View {
        Section {
            LabeledContent {
                HStack(spacing: HopSpacing.md) {
                    if appState.isCustomProfileShortcut {
                        // Switcher family — Shift must be stripped at record time.
                        ShortcutRecorderView(shortcut: $appState.customProfileShortcut, mode: .shiftInsensitive)
                    } else {
                        Text("\(appState.profileShortcutModifierName) + \(appState.profileShortcutKeyName)")
                            .font(.hopSubheading.weight(.medium))
                            .padding(.horizontal, HopSpacing.sm + 2)
                            .padding(.vertical, HopSpacing.xs + 2)
                            .background(
                                RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                                    .fill(Color.primary.opacity(0.06))
                            )
                    }
                    Text("Custom")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                    Toggle("Custom", isOn: $appState.isCustomProfileShortcut)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .accessibilityLabel("Use a custom workspace switcher shortcut")
                }
            } label: {
                Text("Shortcut")
            }

            if appState.shortcutsConflict {
                conflictBanner
            }
        } header: {
            Text("Workspace Switcher")
        } footer: {
            Text("Hold the modifier and tap the key to pick a workspace; release to switch. Each workspace can also have its own hotkey, set under Workspaces.")
        }
    }

    private var commandPaletteSection: some View {
        Section {
            Toggle(isOn: $appState.commandPaletteEnabled) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open the palette with \(appState.effectiveCommandPaletteShortcut.displayName)")
                    Text("Type to find a workspace, an app, a Chrome tab or a page from your history. Enter opens it.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            LabeledContent {
                HStack(spacing: HopSpacing.sm) {
                    ShortcutRecorderView(shortcut: $appState.commandPaletteShortcut)
                    if appState.commandPaletteShortcut != nil {
                        Button("Reset") { appState.commandPaletteShortcut = nil }
                            .controlSize(.small)
                    }
                }
            } label: {
                Text("Shortcut")
            }
            .disabled(!appState.commandPaletteEnabled)

            Toggle(isOn: $appState.commandPaletteIncludesChrome) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Include Google Chrome")
                    Text("Open tabs, bookmarks and 30 days of history from every Chrome profile. macOS will ask once to let HopTab control Chrome.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(!appState.commandPaletteEnabled || !ChromeDataService.isInstalled)
        } header: {
            Text("Command Palette")
        } footer: {
            Text("Some apps use \u{2318}K for their own search. Record a different shortcut here if you want theirs back, or turn the palette off.")
        }
    }

    private var howItWorksSection: some View {
        Section {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: HopSpacing.xs) {
                    let sel = appState.appShortcutSelection
                    shortcutHint("\(sel.modifierName)+\(sel.keyName)", "Show switcher & cycle forward")
                    shortcutHint("Shift+\(sel.modifierName)+\(sel.keyName)", "Cycle backward")
                    shortcutHint("Release \(sel.modifierName)", "Activate selected")
                    shortcutHint("Esc", "Cancel")
                    shortcutHint("\u{2318}Q / \u{2318}H / \u{2318}M", "Quit / Hide / Minimize")
                    Divider().padding(.vertical, 2)
                    shortcutHint("\(appState.profileShortcutModifierName)+\(appState.profileShortcutKeyName)", "Show profile switcher")
                }
                .padding(.top, HopSpacing.xs + 2)
            } label: {
                Text("Quick Reference")
                    .font(.hopSubheading)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func shortcutHint(_ keys: String, _ description: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: HopSpacing.sm) {
            Text(keys)
                .font(.hopCaption.monospaced().weight(.medium))
                .foregroundStyle(.primary)
                .frame(minWidth: 140, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            Text(description)
                .font(.hopCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hotkeyStatusBadge: some View {
        HStack(spacing: HopSpacing.xs) {
            switch appState.hotkeyStatus {
            case .running:
                Circle().fill(HopColor.success).frame(width: 6, height: 6)
                Text("Active").font(.hopFootnote).foregroundStyle(HopColor.success)
            case .failed:
                Circle().fill(HopColor.warning).frame(width: 6, height: 6)
                Text("No access").font(.hopFootnote).foregroundStyle(HopColor.warning)
            case .stopped:
                Circle().fill(Color.gray).frame(width: 6, height: 6)
                Text("Stopped").font(.hopFootnote).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Shortcut status")
    }

    private var conflictBanner: some View {
        HopBanner(
            icon: "exclamationmark.triangle.fill",
            tone: HopColor.warning,
            title: "App and profile shortcuts conflict",
            detail: "The app switcher takes priority \u{2014} the profile switcher will not fire."
        ) {
            EmptyView()
        }
    }

    @ViewBuilder
    private var hotkeyStatusRow: some View {
        VStack(alignment: .leading, spacing: HopSpacing.sm) {
            HStack(spacing: HopSpacing.xs + 2) {
                Text("Status:")
                    .foregroundStyle(.secondary)
                switch appState.hotkeyStatus {
                case .running:
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(HopColor.success)
                        .accessibilityHidden(true)
                    Text("Active")
                        .foregroundStyle(HopColor.success)
                case .failed:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(HopColor.warning)
                        .accessibilityHidden(true)
                    Text("Failed \u{2014} HopTab could not install its keyboard tap")
                        .foregroundStyle(HopColor.warning)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: HopSpacing.sm)
                    Button("Retry") {
                        appState.retryHotkey()
                    }
                    .controlSize(.small)
                case .stopped:
                    Image(systemName: "minus.circle")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Text("Not started")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.hopSubheading)

            // One consistent Accessibility treatment, shared with General.
            if !appState.isAccessibilityTrusted {
                AccessibilityStatusRow()
            }
        }
    }
}

// MARK: - Gap Preferences

enum GapDefaultsKey {
    /// Legacy single gap. Still the fallback for every unset per-edge key.
    static let legacy = "windowGap"
    static let top = "windowGapTop"
    static let bottom = "windowGapBottom"
    static let left = "windowGapLeft"
    static let right = "windowGapRight"
    static let inner = "windowGapInner"
    /// UI-only: remembers whether the user opened the per-edge controls.
    static let perEdge = "windowGapPerEdge"
}

// MARK: - Snapping Section

struct SnappingSection: View {
    @EnvironmentObject private var appState: AppState

    // Drag-to-snap preferences
    @State private var restoreOnUnsnap: Bool =
        UserDefaults.standard.object(forKey: DragSnapService.restoreOnUnsnapDefaultsKey) as? Bool ?? true
    @State private var disableModifier: DragSnapService.DisableModifier = DragSnapService.disableModifier
    @State private var bottomEdgeThirds: Bool = DragSnapService.bottomEdgeThirdsEnabled
    @State private var systemTiling: Bool = DragSnapService.systemEdgeTilingEnabled

    // Gaps
    @AppStorage(GapDefaultsKey.perEdge) private var perEdgeGaps = false
    @State private var gapAll: Double = Double(LayoutService.gapSize)
    @State private var gapTop: Double = Double(LayoutService.gapTop)
    @State private var gapBottom: Double = Double(LayoutService.gapBottom)
    @State private var gapLeft: Double = Double(LayoutService.gapLeft)
    @State private var gapRight: Double = Double(LayoutService.gapRight)
    @State private var gapInner: Double = Double(LayoutService.gapInner)

    // Snap shortcuts
    @State private var snapConfig: SnapShortcutConfig = SnapShortcutConfig.current
    @State private var expandedGroups: Set<String> = Set(
        SnapShortcutConfig.actionGroups.filter { !$0.isUnboundByDefault }.map(\.id)
    )
    @State private var pendingBinding: PendingBinding?
    @State private var confirmReset = false
    @State private var pendingImportURL: URL?
    @State private var shortcutFileError: String?
    @State private var defaultsAddedNote: String?

    private struct PendingBinding: Equatable {
        let direction: SnapDirection
        let shortcut: CustomShortcut
        let conflict: ShortcutConflict
    }

    var body: some View {
        dragSnapSection
        gapsSection
        shortcutsSection
    }

    // MARK: Drag to snap

    private var dragSnapSection: some View {
        Section {
            Toggle("Drag to Snap", isOn: $appState.dragSnapEnabled)

            if appState.dragSnapEnabled {
                Toggle("Restore size when dragging away", isOn: $restoreOnUnsnap)
                    .onChange(of: restoreOnUnsnap) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: DragSnapService.restoreOnUnsnapDefaultsKey)
                    }

                Picker("Hold to move without snapping", selection: $disableModifier) {
                    ForEach(DragSnapService.DisableModifier.allCases, id: \.self) { modifier in
                        Text(modifier.displayName).tag(modifier)
                    }
                }
                .onChange(of: disableModifier) { _, newValue in
                    UserDefaults.standard.set(newValue.rawValue, forKey: DragSnapService.disableModifierDefaultsKey)
                }

                Text(disableModifier == .none
                     ? "No escape hatch \u{2014} every drag to an edge snaps."
                     : "Hold \(disableModifier.displayName) to move a window to an edge without snapping.")
                    .font(.hopCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Split the bottom edge into thirds", isOn: $bottomEdgeThirds)
                    .onChange(of: bottomEdgeThirds) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: DragSnapService.bottomEdgeThirdsDefaultsKey)
                    }

                Text(bottomEdgeThirds
                     ? "Dragging to the bottom edge picks the first, center, or last third by horizontal position."
                     : "Dragging to the bottom edge snaps to the bottom half (the Magnet and Rectangle default).")
                    .font(.hopCaption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if systemTiling {
                    HopBanner(
                        icon: "exclamationmark.triangle.fill",
                        tone: HopColor.warning,
                        title: "macOS is also tiling on edge drags",
                        detail: "System Settings \u{203A} Desktop & Dock \u{203A} \u{201C}Drag windows to screen edges to tile\u{201D} is on. Both macOS and HopTab will place the window. Turn one of them off."
                    ) {
                        Button("Open Desktop & Dock") {
                            openDesktopAndDockSettings()
                        }
                        .controlSize(.small)
                    }
                }
            }
        } header: {
            Text("Drag to Snap")
        } footer: {
            Text(appState.dragSnapEnabled
                 ? "Drag any window to a screen edge or corner to snap it into position. May use slightly more CPU while enabled."
                 : "Drag any window to a screen edge or corner to snap it into position.")
        }
        .onAppear {
            DragSnapService.refreshSystemTilingState()
            systemTiling = DragSnapService.systemEdgeTilingEnabled
            disableModifier = DragSnapService.disableModifier
            bottomEdgeThirds = DragSnapService.bottomEdgeThirdsEnabled
        }
    }

    private func openDesktopAndDockSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.dock"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) { return }
        }
    }

    // MARK: Gaps

    private var gapsSection: some View {
        Section {
            LabeledContent("Window Gap") {
                HStack(spacing: HopSpacing.md) {
                    gapPreview
                    Slider(value: $gapAll, in: 0...40, step: 1)
                        .frame(minWidth: 120)
                        .disabled(perEdgeGaps)
                        .accessibilityLabel("Window gap")
                        .accessibilityValue("\(Int(gapAll)) points")
                        .onChange(of: gapAll) { _, newValue in
                            guard !perEdgeGaps else { return }
                            applyUniformGap(newValue)
                        }
                    Text("\(Int(gapAll)) pt")
                        .font(.hopCaption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 38, alignment: .trailing)
                }
            }

            DisclosureGroup(isExpanded: $perEdgeGaps) {
                VStack(alignment: .leading, spacing: HopSpacing.sm) {
                    gapSlider("Top", value: $gapTop, key: GapDefaultsKey.top)
                    gapSlider("Bottom", value: $gapBottom, key: GapDefaultsKey.bottom)
                    gapSlider("Left", value: $gapLeft, key: GapDefaultsKey.left)
                    gapSlider("Right", value: $gapRight, key: GapDefaultsKey.right)
                    Divider()
                    gapSlider("Between windows", value: $gapInner, key: GapDefaultsKey.inner)
                    Text("Outer gaps apply where a window touches the screen edge; the inner gap is the total space between two neighbours (each takes half).")
                        .font(.hopFootnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Match all edges to \(Int(gapAll)) pt") {
                        applyUniformGap(gapAll)
                    }
                    .controlSize(.small)
                }
                .padding(.top, HopSpacing.xs)
            } label: {
                Text("Advanced \u{2014} per-edge gaps")
                    .font(.hopSubheading)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Gaps")
        } footer: {
            Text("Space left around snapped windows. 0 pt means edge-to-edge.")
        }
    }

    private func gapSlider(_ title: String, value: Binding<Double>, key: String) -> some View {
        LabeledContent(title) {
            HStack(spacing: HopSpacing.sm) {
                Slider(value: value, in: 0...40, step: 1)
                    .frame(minWidth: 120)
                    .accessibilityLabel("\(title) gap")
                    .accessibilityValue("\(Int(value.wrappedValue)) points")
                    .onChange(of: value.wrappedValue) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: key)
                    }
                Text("\(Int(value.wrappedValue)) pt")
                    .font(.hopCaption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 38, alignment: .trailing)
            }
        }
    }

    private func applyUniformGap(_ value: Double) {
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: GapDefaultsKey.legacy)
        defaults.set(value, forKey: GapDefaultsKey.top)
        defaults.set(value, forKey: GapDefaultsKey.bottom)
        defaults.set(value, forKey: GapDefaultsKey.left)
        defaults.set(value, forKey: GapDefaultsKey.right)
        defaults.set(value, forKey: GapDefaultsKey.inner)
        gapTop = value
        gapBottom = value
        gapLeft = value
        gapRight = value
        gapInner = value
    }

    /// Live preview — the one genuinely delightful control in this window.
    /// Now shows each edge independently plus the inner gap.
    private var gapPreview: some View {
        let scale: (Double) -> CGFloat = { CGFloat(min($0, 24) / 3) }
        // The preview is an 86x44 glyph, so it uses a scaled-down radius rather
        // than a control-sized one.
        let previewCorner = HopRadius.control / 3
        return HStack(spacing: max(scale(gapInner), 0)) {
            RoundedRectangle(cornerRadius: previewCorner, style: .continuous)
                .fill(Color.accentColor.opacity(0.45))
            RoundedRectangle(cornerRadius: previewCorner, style: .continuous)
                .fill(Color.accentColor.opacity(0.28))
        }
        .padding(.top, scale(gapTop))
        .padding(.bottom, scale(gapBottom))
        .padding(.leading, scale(gapLeft))
        .padding(.trailing, scale(gapRight))
        .frame(width: 86, height: 44)
        .background(
            RoundedRectangle(cornerRadius: HopRadius.control, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .animation(HopMotion.snappy, value: gapTop)
        .animation(HopMotion.snappy, value: gapBottom)
        .animation(HopMotion.snappy, value: gapLeft)
        .animation(HopMotion.snappy, value: gapRight)
        .animation(HopMotion.snappy, value: gapInner)
        .accessibilityHidden(true)
    }

    // MARK: Snap shortcuts

    private var shortcutsSection: some View {
        Section {
            if !allConflicts.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(allConflicts) { conflict in
                        Label(conflict.message, systemImage: "exclamationmark.triangle.fill")
                            .font(.hopCaption)
                            .foregroundStyle(HopColor.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(HopSpacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: HopRadius.card, style: .continuous)
                        .fill(HopColor.tint(HopColor.warning))
                )
            }

            if let note = defaultsAddedNote {
                Label(note, systemImage: "checkmark.circle.fill")
                    .font(.hopCaption)
                    .foregroundStyle(HopColor.success)
            }

            ForEach(SnapShortcutConfig.actionGroups) { group in
                if group.id == SnapShortcutConfig.actionGroups.first(where: \.isUnboundByDefault)?.id {
                    Text("More (Rectangle extras)")
                        .font(.hopFootnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .textCase(.uppercase)
                        .padding(.top, HopSpacing.md)
                }
                if group.isUnboundByDefault {
                    DisclosureGroup(isExpanded: expansionBinding(for: group)) {
                        groupGrid(group)
                            .padding(.top, HopSpacing.xs)
                    } label: {
                        HStack(spacing: HopSpacing.xs) {
                            Text(group.title)
                                .font(.hopSubheading)
                            Text("\(boundCount(in: group)) of \(group.directions.count) bound")
                                .font(.hopFootnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: HopSpacing.xs) {
                        Text(group.title)
                            .font(.hopFootnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .textCase(.uppercase)
                            .padding(.top, HopSpacing.xs + 2)
                        groupGrid(group)
                    }
                }
            }

            shortcutToolbar
        } header: {
            Text("Snap Shortcuts")
        } footer: {
            Text("Global hotkeys to snap windows. Press the same key twice to cycle sizes. Shift is part of a snap shortcut \u{2014} \u{2303}\u{2325}Z and \u{2303}\u{2325}\u{21E7}Z are Undo and Redo.")
        }
        .alert(
            "Shortcut already in use",
            isPresented: Binding(
                get: { pendingBinding != nil },
                set: { if !$0 { pendingBinding = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingBinding = nil }
            Button("Use Anyway") {
                if let pending = pendingBinding {
                    snapConfig.bindings[pending.direction] = pending.shortcut
                    saveConfig()
                }
                pendingBinding = nil
            }
        } message: {
            if let pending = pendingBinding {
                Text("\(pending.shortcut.displayName) conflicts with \(pending.conflict.message). Assigning it to \(pending.direction.displayName) anyway means only one of them will fire.")
            } else {
                Text("")
            }
        }
        .alert("Reset all snap shortcuts?", isPresented: $confirmReset) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                snapConfig = .defaults
                saveConfig()
            }
        } message: {
            Text("Every snap shortcut goes back to the HopTab defaults. Any combination you recorded yourself is lost. Export first if you want a copy.")
        }
        .alert(
            "Replace all snap shortcuts?",
            isPresented: Binding(
                get: { pendingImportURL != nil },
                set: { if !$0 { pendingImportURL = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { pendingImportURL = nil }
            Button("Replace", role: .destructive) {
                if let url = pendingImportURL { performImport(from: url) }
                pendingImportURL = nil
            }
        } message: {
            Text("Importing replaces every snap shortcut with the ones in the file. Nothing is merged. If the file is unreadable, your current shortcuts are left untouched.")
        }
        .alert(
            "Couldn't import shortcuts",
            isPresented: Binding(
                get: { shortcutFileError != nil },
                set: { if !$0 { shortcutFileError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { shortcutFileError = nil }
        } message: {
            Text(shortcutFileError ?? "")
        }
    }

    private var shortcutToolbar: some View {
        VStack(alignment: .leading, spacing: HopSpacing.sm) {
            Divider()
            HStack(spacing: HopSpacing.sm) {
                Button {
                    exportShortcuts()
                } label: {
                    Label("Export\u{2026}", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)

                Button {
                    pickImportFile()
                } label: {
                    Label("Import\u{2026}", systemImage: "square.and.arrow.down")
                }
                .controlSize(.small)

                Spacer(minLength: HopSpacing.sm)

                Button("Reset\u{2026}") { confirmReset = true }
                    .controlSize(.small)
                    .foregroundStyle(HopColor.danger)
            }

            if !snapConfig.unboundDirections.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: HopSpacing.sm) {
                    Button("Add new default shortcuts") { addMissingDefaults() }
                        .controlSize(.small)
                    Text("\(snapConfig.unboundDirections.count) action\(snapConfig.unboundDirections.count == 1 ? " has" : "s have") no shortcut. This only fills empty ones \u{2014} it never changes a combination you set.")
                        .font(.hopFootnote)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func groupGrid(_ group: SnapActionGroup) -> some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 260), spacing: HopSpacing.sm)],
            alignment: .leading,
            spacing: HopSpacing.xs
        ) {
            ForEach(group.directions, id: \.self) { direction in
                snapShortcutRow(direction: direction)
            }
        }
    }

    private func expansionBinding(for group: SnapActionGroup) -> Binding<Bool> {
        Binding(
            get: { expandedGroups.contains(group.id) },
            set: { isOpen in
                if isOpen { expandedGroups.insert(group.id) } else { expandedGroups.remove(group.id) }
            }
        )
    }

    private func boundCount(in group: SnapActionGroup) -> Int {
        group.directions.filter { snapConfig.bindings[$0] != nil }.count
    }

    private func snapShortcutRow(direction: SnapDirection) -> some View {
        let conflict = snapConfig.conflict(for: direction, against: externalShortcuts)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: HopSpacing.xs) {
                Text(direction.displayName)
                    .font(.hopCaption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if conflict != nil {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.hopFootnote)
                        .foregroundStyle(HopColor.warning)
                        .accessibilityHidden(true)
                }

                // Snap family: `.exactModifiers` (the default) — Shift is part
                // of the binding here, so it must NOT be stripped.
                ShortcutRecorderView(shortcut: binding(for: direction))
                    .frame(minWidth: 92)

                if snapConfig.bindings[direction] != nil {
                    Button {
                        snapConfig.bindings.removeValue(forKey: direction)
                        saveConfig()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.hopFootnote)
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear the \(direction.displayName) shortcut")
                } else {
                    Color.clear.frame(width: 14, height: 1)
                }
            }

            if let conflict {
                Text("Conflicts with \(conflict.message).")
                    .font(.hopFootnote)
                    .foregroundStyle(HopColor.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func binding(for direction: SnapDirection) -> Binding<CustomShortcut?> {
        Binding(
            get: { snapConfig.bindings[direction] },
            set: { newValue in
                guard let shortcut = newValue else {
                    snapConfig.bindings.removeValue(forKey: direction)
                    saveConfig()
                    return
                }
                // Warn BEFORE committing, not after.
                if let conflict = snapConfig.conflict(
                    for: shortcut,
                    excluding: direction,
                    against: externalShortcuts
                ) {
                    pendingBinding = PendingBinding(
                        direction: direction,
                        shortcut: shortcut,
                        conflict: conflict
                    )
                    return
                }
                snapConfig.bindings[direction] = shortcut
                saveConfig()
            }
        )
    }

    private func saveConfig() {
        SnapShortcutConfig.current = snapConfig
        NotificationCenter.default.post(name: .snapShortcutsChanged, object: nil)
    }

    // MARK: Conflicts

    /// HopTab shortcuts owned outside `SnapShortcutConfig`, so the shared
    /// conflict engine can see them.
    private var externalShortcuts: [NamedShortcut] {
        var out: [NamedShortcut] = []
        let sel = appState.appShortcutSelection
        out.append(NamedShortcut(
            name: "the app switcher shortcut",
            shortcut: CustomShortcut(
                modifierFlagsRawValue: sel.modifierFlags.rawValue,
                keyCode: sel.keyCode
            )
        ))
        if appState.isCustomProfileShortcut, let profileShortcut = appState.customProfileShortcut {
            out.append(NamedShortcut(name: "the profile switcher shortcut", shortcut: profileShortcut))
        }
        for profile in appState.store.profiles {
            if let hotkey = profile.hotkey {
                out.append(NamedShortcut(name: "the \(profile.name) profile hotkey", shortcut: hotkey))
            }
        }
        return out
    }

    private var allConflicts: [SnapShortcutConflict] {
        snapConfig.conflicts(against: externalShortcuts)
    }

    // MARK: Import / export / defaults

    private func addMissingDefaults() {
        let before = snapConfig.bindings.count
        snapConfig = snapConfig.applyingMissingDefaults()
        saveConfig()
        let added = snapConfig.bindings.count - before
        defaultsAddedNote = added == 0
            ? "No new defaults could be added without clashing with your shortcuts."
            : "Added \(added) default shortcut\(added == 1 ? "" : "s")."
    }

    private func exportShortcuts() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "HopTab Shortcuts.json"
        panel.canCreateDirectories = true
        panel.message = "Save your snap shortcuts as a JSON file you can import on another Mac."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try snapConfig.exportJSON()
            try data.write(to: url, options: .atomic)
        } catch {
            shortcutFileError = "Couldn't write that file: \(error.localizedDescription)"
        }
    }

    private func pickImportFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a HopTab shortcuts JSON file."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pendingImportURL = url
    }

    /// The import API is atomic: on any error the current config is untouched.
    private func performImport(from url: URL) {
        do {
            let data = try Data(contentsOf: url)
            snapConfig = try SnapShortcutConfig.importJSON(data)
            saveConfig()
            defaultsAddedNote = "Imported \(snapConfig.bindings.count) shortcut\(snapConfig.bindings.count == 1 ? "" : "s")."
        } catch let error as ShortcutImportError {
            shortcutFileError = error.errorDescription ?? "That file isn't a HopTab shortcut export."
        } catch {
            shortcutFileError = "Couldn't read that file: \(error.localizedDescription)"
        }
    }
}
