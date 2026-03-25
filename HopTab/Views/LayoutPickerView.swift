import SwiftUI

// MARK: - Layouts Tab (full Settings tab)

struct LayoutsTab: View {
    @EnvironmentObject private var appState: AppState

    private var profile: Profile? {
        appState.store.activeProfile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Profile selector
            HStack {
                Text("Profile:")
                    .foregroundStyle(.secondary)
                Text(profile?.name ?? "None")
                    .fontWeight(.medium)
                Spacer()
                profilePicker
            }
            .font(.system(size: 12))

            if let profile {
                LayoutPickerContent(profile: profile)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "rectangle.3.group")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("Create a profile first to configure layouts")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding()
    }

    private var profilePicker: some View {
        Menu {
            ForEach(appState.store.profiles) { p in
                Button {
                    appState.activateProfile(id: p.id)
                } label: {
                    HStack {
                        Text(p.name)
                        if p.id == appState.store.activeProfileId {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Switch")
                Image(systemName: "chevron.down")
                    .font(.system(size: 9))
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

// MARK: - Layout Picker Content

private struct LayoutPickerContent: View {
    @EnvironmentObject private var appState: AppState
    let profile: Profile

    @State private var selectedTemplateId: UUID?
    @State private var showingEditor = false
    @State private var editingTemplate: LayoutTemplate?

    private var currentBinding: LayoutBinding? {
        profile.layoutBinding
    }

    private var templates: [LayoutTemplate] {
        appState.store.allTemplates
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Template grid — 3 columns with bigger cards
                GroupBox("Choose a Template") {
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 10) {
                        ForEach(templates) { template in
                            TemplateCard(
                                template: template,
                                isSelected: selectedTemplateId == template.id,
                                hasBinding: currentBinding?.templateId == template.id
                            )
                            .overlay(alignment: .topTrailing) {
                                if !template.isBuiltIn {
                                    HStack(spacing: 2) {
                                        Button {
                                            editingTemplate = template
                                            showingEditor = true
                                        } label: {
                                            Image(systemName: "pencil.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)

                                        Button {
                                            appState.store.deleteCustomTemplate(id: template.id)
                                            if selectedTemplateId == template.id {
                                                selectedTemplateId = nil
                                            }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.system(size: 14))
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(4)
                                }
                            }
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3)) {
                                    if selectedTemplateId == template.id {
                                        selectedTemplateId = nil
                                    } else {
                                        selectedTemplateId = template.id
                                    }
                                }
                            }
                        }

                        // "New Layout" card
                        Button {
                            editingTemplate = nil
                            showingEditor = true
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Color.primary.opacity(0.04))
                                    .overlay(
                                        Image(systemName: "plus")
                                            .font(.system(size: 20))
                                            .foregroundStyle(.secondary)
                                    )
                                    .frame(height: 56)
                                Text("New Layout")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.02))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.primary.opacity(0.06), lineWidth: 1)
                                    .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4]))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(6)
                }
                .sheet(isPresented: $showingEditor) {
                    CustomLayoutEditorView(
                        existingTemplate: editingTemplate,
                        onSave: { template in
                            if editingTemplate != nil {
                                appState.store.updateCustomTemplate(template)
                            } else {
                                appState.store.addCustomTemplate(template)
                            }
                            showingEditor = false
                        },
                        onCancel: {
                            showingEditor = false
                        }
                    )
                }

                // Zone assignments
                if let templateId = selectedTemplateId,
                   let template = templates.first(where: { $0.id == templateId }) {
                    // Show assignments for the selected template
                    // (may differ from the stored binding if user is browsing)
                    let isActiveTemplate = currentBinding?.templateId == templateId

                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(template.zones) { zone in
                                ZoneAssignmentRow(
                                    zone: zone,
                                    templateId: templateId,
                                    profile: profile
                                )
                            }
                        }
                        .padding(4)
                    } label: {
                        HStack {
                            Text("Assign Apps to Zones")
                            Spacer()
                            if !isActiveTemplate {
                                Text("Assign apps to use this template")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else if profile.pinnedApps.isEmpty {
                                Text("Pin some apps first")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    // Apply button — only show when this template has assignments
                    if isActiveTemplate,
                       let binding = currentBinding,
                       !binding.zoneAssignments.isEmpty {
                        Button {
                            appState.applyLayoutForActiveProfile()
                        } label: {
                            HStack {
                                Spacer()
                                Image(systemName: "rectangle.3.group")
                                Text("Apply Layout Now")
                                    .fontWeight(.medium)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .onAppear {
            selectedTemplateId = currentBinding?.templateId
        }
        .onChange(of: profile.layoutBinding) {
            selectedTemplateId = profile.layoutBinding?.templateId
        }
    }
}

// MARK: - Template Card

private struct TemplateCard: View {
    let template: LayoutTemplate
    let isSelected: Bool
    var hasBinding: Bool = false

    var body: some View {
        VStack(spacing: 6) {
            // Zone preview
            GeometryReader { geo in
                ZStack {
                    ForEach(template.zones) { zone in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3)
                                    .stroke(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.15), lineWidth: 1)
                            )
                            .frame(
                                width: geo.size.width * zone.width - 3,
                                height: geo.size.height * zone.height - 3
                            )
                            .position(
                                x: geo.size.width * (zone.x + zone.width / 2),
                                y: geo.size.height * (zone.y + zone.height / 2)
                            )
                    }
                }
            }
            .frame(height: 56)

            HStack(spacing: 4) {
                if hasBinding {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.green)
                }
                Text(template.name)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                    .lineLimit(1)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.06), lineWidth: isSelected ? 2 : 1)
        )
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.25), value: isSelected)
    }
}

// MARK: - Zone Assignment Row

private struct ZoneAssignmentRow: View {
    @EnvironmentObject private var appState: AppState
    let zone: LayoutZone
    let templateId: UUID
    let profile: Profile

    private var assignedBundle: String? {
        profile.layoutBinding?.zoneAssignments[zone.id]
    }

    private var assignedApp: PinnedApp? {
        guard let bundle = assignedBundle else { return nil }
        return profile.pinnedApps.first { $0.bundleIdentifier == bundle }
    }

    var body: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.accentColor.opacity(0.3))
                .frame(width: 4, height: 24)

            Text(zone.name)
                .font(.system(size: 12))
                .frame(width: 90, alignment: .leading)

            if let app = assignedApp {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 18, height: 18)
                Text(app.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Spacer()
                Button {
                    appState.store.unassignZone(profileId: profile.id, zoneId: zone.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(profile.pinnedApps) { app in
                        Button {
                            appState.store.assignZone(
                                profileId: profile.id,
                                templateId: templateId,
                                zoneId: zone.id,
                                bundleIdentifier: app.bundleIdentifier
                            )
                        } label: {
                            HStack {
                                Image(nsImage: app.icon)
                                    .resizable()
                                    .frame(width: 16, height: 16)
                                Text(app.displayName)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 11))
                        Text("Assign app\u{2026}")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(.secondary)
                }
                .fixedSize()
                Spacer()
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Custom Layout Editor

private struct CustomLayoutEditorView: View {
    let existingTemplate: LayoutTemplate?
    let onSave: (LayoutTemplate) -> Void
    let onCancel: () -> Void

    @State private var layoutName: String
    @State private var zones: [LayoutZone]
    @State private var selectedZoneId: UUID?

    init(existingTemplate: LayoutTemplate?, onSave: @escaping (LayoutTemplate) -> Void, onCancel: @escaping () -> Void) {
        self.existingTemplate = existingTemplate
        self.onSave = onSave
        self.onCancel = onCancel

        if let existing = existingTemplate {
            _layoutName = State(initialValue: existing.name)
            _zones = State(initialValue: existing.zones)
        } else {
            _layoutName = State(initialValue: "")
            _zones = State(initialValue: [
                LayoutZone(id: UUID(), name: "Full", x: 0, y: 0, width: 1, height: 1)
            ])
        }
    }

    private var selectedZone: LayoutZone? {
        zones.first { $0.id == selectedZoneId }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(existingTemplate != nil ? "Edit Layout" : "New Custom Layout")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            VStack(spacing: 16) {
                // Name field
                HStack {
                    Text("Name:")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("My Layout", text: $layoutName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                }

                // Visual canvas
                GroupBox("Preview") {
                    GeometryReader { geo in
                        ZStack {
                            ForEach(zones) { zone in
                                let isSelected = zone.id == selectedZoneId
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.07))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                                    )
                                    .overlay(
                                        Text(zone.name)
                                            .font(.system(size: 10))
                                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                            .lineLimit(1)
                                    )
                                    .frame(
                                        width: geo.size.width * zone.width - 4,
                                        height: geo.size.height * zone.height - 4
                                    )
                                    .position(
                                        x: geo.size.width * (zone.x + zone.width / 2),
                                        y: geo.size.height * (zone.y + zone.height / 2)
                                    )
                                    .onTapGesture {
                                        withAnimation(.easeInOut(duration: 0.15)) {
                                            selectedZoneId = zone.id
                                        }
                                    }
                            }
                        }
                    }
                    .frame(height: 140)
                    .padding(4)
                }

                // Zone controls
                if let zone = selectedZone {
                    GroupBox("Selected Zone") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Name:")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.secondary)
                                TextField("Zone", text: Binding(
                                    get: { zone.name },
                                    set: { newName in
                                        if let idx = zones.firstIndex(where: { $0.id == zone.id }) {
                                            zones[idx].name = newName
                                        }
                                    }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12))
                            }

                            HStack(spacing: 8) {
                                Button {
                                    splitZone(zone, horizontal: true)
                                } label: {
                                    Label("Split H", systemImage: "rectangle.split.1x2")
                                        .font(.system(size: 11))
                                }

                                Button {
                                    splitZone(zone, horizontal: false)
                                } label: {
                                    Label("Split V", systemImage: "rectangle.split.2x1")
                                        .font(.system(size: 11))
                                }

                                if zones.count > 1 {
                                    Button(role: .destructive) {
                                        zones.removeAll { $0.id == zone.id }
                                        selectedZoneId = zones.first?.id
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                            .font(.system(size: 11))
                                    }
                                }
                            }
                        }
                        .padding(4)
                    }
                } else {
                    GroupBox("Selected Zone") {
                        Text("Tap a zone in the preview to select it")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(8)
                    }
                }

                // Presets
                GroupBox("Start From Preset") {
                    HStack(spacing: 8) {
                        Button("2 Columns") { applyPreset(columns: 2) }
                        Button("3 Columns") { applyPreset(columns: 3) }
                        Button("2\u{00d7}2 Grid") { applyGridPreset() }
                        Button("Top + Bottom") { applyTopBottomPreset() }
                    }
                    .font(.system(size: 11))
                    .padding(4)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(layoutName.trimmingCharacters(in: .whitespaces).isEmpty || zones.isEmpty)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 420)
    }

    // MARK: - Actions

    private func splitZone(_ zone: LayoutZone, horizontal: Bool) {
        guard let idx = zones.firstIndex(where: { $0.id == zone.id }) else { return }

        let z = zones[idx]
        zones.remove(at: idx)

        if horizontal {
            // Split into left and right
            let left = LayoutZone(id: UUID(), name: "\(z.name) L", x: z.x, y: z.y, width: z.width / 2, height: z.height)
            let right = LayoutZone(id: UUID(), name: "\(z.name) R", x: z.x + z.width / 2, y: z.y, width: z.width / 2, height: z.height)
            zones.insert(contentsOf: [left, right], at: idx)
            selectedZoneId = left.id
        } else {
            // Split into top and bottom
            let top = LayoutZone(id: UUID(), name: "\(z.name) T", x: z.x, y: z.y, width: z.width, height: z.height / 2)
            let bottom = LayoutZone(id: UUID(), name: "\(z.name) B", x: z.x, y: z.y + z.height / 2, width: z.width, height: z.height / 2)
            zones.insert(contentsOf: [top, bottom], at: idx)
            selectedZoneId = top.id
        }
    }

    private func applyPreset(columns: Int) {
        let w = 1.0 / Double(columns)
        zones = (0..<columns).map { i in
            LayoutZone(id: UUID(), name: "Column \(i + 1)", x: Double(i) * w, y: 0, width: w, height: 1)
        }
        selectedZoneId = zones.first?.id
    }

    private func applyGridPreset() {
        zones = [
            LayoutZone(id: UUID(), name: "Top Left", x: 0, y: 0, width: 0.5, height: 0.5),
            LayoutZone(id: UUID(), name: "Top Right", x: 0.5, y: 0, width: 0.5, height: 0.5),
            LayoutZone(id: UUID(), name: "Bottom Left", x: 0, y: 0.5, width: 0.5, height: 0.5),
            LayoutZone(id: UUID(), name: "Bottom Right", x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        ]
        selectedZoneId = zones.first?.id
    }

    private func applyTopBottomPreset() {
        zones = [
            LayoutZone(id: UUID(), name: "Top", x: 0, y: 0, width: 1, height: 0.5),
            LayoutZone(id: UUID(), name: "Bottom", x: 0, y: 0.5, width: 1, height: 0.5),
        ]
        selectedZoneId = zones.first?.id
    }

    private func save() {
        let name = layoutName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !zones.isEmpty else { return }

        let template = LayoutTemplate(
            id: existingTemplate?.id ?? UUID(),
            name: name,
            zones: zones,
            isBuiltIn: false
        )
        onSave(template)
    }
}
