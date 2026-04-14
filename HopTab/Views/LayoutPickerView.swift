import SwiftUI

// MARK: - Layout Picker Content

struct LayoutPickerContent: View {
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
        VStack(alignment: .leading, spacing: 20) {
            // Template grid
            VStack(alignment: .leading, spacing: 10) {
                Text("Choose a Template")
                    .font(.system(size: 13, weight: .semibold))
                Text("Pick a layout template and assign apps to zones. When you apply the layout, each app snaps to its assigned position.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

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

                    // "Custom Layout" card — Pro feature
                    Button {
                        if ProFeatureGate.isLicensed {
                            editingTemplate = nil
                            showingEditor = true
                        }
                    } label: {
                        VStack(spacing: 6) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(ProFeatureGate.isLicensed
                                          ? Color.primary.opacity(0.04)
                                          : Color.yellow.opacity(0.06))
                                    .frame(height: 56)

                                if ProFeatureGate.isLicensed {
                                    Image(systemName: "plus")
                                        .font(.system(size: 20))
                                        .foregroundStyle(.secondary)
                                } else {
                                    VStack(spacing: 4) {
                                        Image(systemName: "rectangle.3.group.fill")
                                            .font(.system(size: 16))
                                            .foregroundStyle(.yellow.opacity(0.7))
                                        HStack(spacing: 3) {
                                            Image(systemName: "star.fill")
                                                .font(.system(size: 7))
                                            Text("PRO")
                                                .font(.system(size: 8, weight: .bold))
                                        }
                                        .foregroundStyle(.yellow)
                                    }
                                }
                            }

                            if ProFeatureGate.isLicensed {
                                Text("New Layout")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Custom Layout")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(ProFeatureGate.isLicensed
                                      ? Color.primary.opacity(0.02)
                                      : Color.yellow.opacity(0.03))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(ProFeatureGate.isLicensed
                                        ? Color.primary.opacity(0.06)
                                        : Color.yellow.opacity(0.2),
                                        lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            if !ProFeatureGate.isLicensed {
                HStack(spacing: 6) {
                    Image(systemName: "star.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.yellow)
                    Text("Custom layouts with exact percentages")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Link("Unlock", destination: URL(string: "https://buy.polar.sh/polar_cl_iKgZQ7w4AWRhnNzsnQBl80syKnFJGHJj1Pv6d2a9tD7")!)
                        .font(.system(size: 11))
                }
            }

            Color.clear.frame(height: 0)
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
                let isActiveTemplate = currentBinding?.templateId == templateId

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Assign Apps to Zones")
                            .font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if profile.pinnedApps.isEmpty {
                            Text("Pin some apps first")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange)
                        } else if !isActiveTemplate {
                            Text("Assign apps to use this template")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(template.zones) { zone in
                            ZoneAssignmentRow(
                                zone: zone,
                                templateId: templateId,
                                profile: profile
                            )
                        }
                    }
                }

                // Apply button
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
                    if profile.pinnedApps.isEmpty {
                        Text("No pinned apps \u{2014} pin apps first")
                    } else {
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

private struct DraggableEdge: Equatable {
    let isVertical: Bool
    let position: Double
    let rangeStart: Double
    let rangeEnd: Double
}

private struct CustomLayoutEditorView: View {
    let existingTemplate: LayoutTemplate?
    let onSave: (LayoutTemplate) -> Void
    let onCancel: () -> Void

    @State private var layoutName: String
    @State private var zones: [LayoutZone]
    @State private var selectedZoneId: UUID?
    @State private var draggingEdge: DraggableEdge?
    @State private var dragStartZones: [LayoutZone]?

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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Preview")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    GeometryReader { geo in
                        ZStack {
                            // Zone rectangles
                            ForEach(zones) { zone in
                                let isSelected = zone.id == selectedZoneId
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(isSelected ? Color.accentColor.opacity(0.3) : Color.primary.opacity(0.07))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 4)
                                            .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.2), lineWidth: isSelected ? 2 : 1)
                                    )
                                    .overlay(
                                        VStack(spacing: 1) {
                                            Text(zone.name)
                                                .font(.system(size: 10))
                                                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                                                .lineLimit(1)
                                            Text("\(Int(round(zone.width * 100))) \u{00d7} \(Int(round(zone.height * 100)))%")
                                                .font(.system(size: 8))
                                                .foregroundStyle(isSelected ? Color.accentColor.opacity(0.7) : .secondary.opacity(0.7))
                                        }
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

                            // Draggable edge handles
                            ForEach(Array(findDraggableEdges().enumerated()), id: \.offset) { _, edge in
                                if edge.isVertical {
                                    Color.clear
                                        .frame(width: 14, height: geo.size.height * (edge.rangeEnd - edge.rangeStart) - 8)
                                        .contentShape(Rectangle())
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 1.5)
                                                .fill(Color.accentColor.opacity(draggingEdge == edge ? 0.7 : 0.4))
                                                .frame(width: 4)
                                        )
                                        .position(
                                            x: geo.size.width * edge.position,
                                            y: geo.size.height * (edge.rangeStart + edge.rangeEnd) / 2
                                        )
                                        .gesture(
                                            DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                                                .onChanged { value in
                                                    if dragStartZones == nil {
                                                        dragStartZones = zones
                                                        draggingEdge = edge
                                                    }
                                                    if let startZones = dragStartZones, let activeEdge = draggingEdge {
                                                        zones = adjustedZones(from: startZones, edge: activeEdge, to: value.location.x / geo.size.width)
                                                    }
                                                }
                                                .onEnded { _ in
                                                    dragStartZones = nil
                                                    draggingEdge = nil
                                                }
                                        )
                                        .onHover { hovering in
                                            if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                                        }
                                } else {
                                    Color.clear
                                        .frame(width: geo.size.width * (edge.rangeEnd - edge.rangeStart) - 8, height: 14)
                                        .contentShape(Rectangle())
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 1.5)
                                                .fill(Color.accentColor.opacity(draggingEdge == edge ? 0.7 : 0.4))
                                                .frame(height: 4)
                                        )
                                        .position(
                                            x: geo.size.width * (edge.rangeStart + edge.rangeEnd) / 2,
                                            y: geo.size.height * edge.position
                                        )
                                        .gesture(
                                            DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas"))
                                                .onChanged { value in
                                                    if dragStartZones == nil {
                                                        dragStartZones = zones
                                                        draggingEdge = edge
                                                    }
                                                    if let startZones = dragStartZones, let activeEdge = draggingEdge {
                                                        zones = adjustedZones(from: startZones, edge: activeEdge, to: value.location.y / geo.size.height)
                                                    }
                                                }
                                                .onEnded { _ in
                                                    dragStartZones = nil
                                                    draggingEdge = nil
                                                }
                                        )
                                        .onHover { hovering in
                                            if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                                        }
                                }
                            }
                        }
                        .coordinateSpace(name: "canvas")
                    }
                    .frame(height: 160)

                    if zones.count > 1 {
                        Text("Drag edges to resize zones")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }

                // Zone controls
                VStack(alignment: .leading, spacing: 6) {
                    Text("Selected Zone")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    if let zone = selectedZone {
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

                            HStack(spacing: 12) {
                                HStack(spacing: 4) {
                                    Text("W:")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    TextField("", value: Binding(
                                        get: { Int(round(zone.width * 100)) },
                                        set: { newValue in
                                            let clamped = Double(max(5, min(95, newValue))) / 100.0
                                            setZoneWidth(zone, to: clamped)
                                        }
                                    ), format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 44)
                                    Text("%")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }

                                HStack(spacing: 4) {
                                    Text("H:")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                    TextField("", value: Binding(
                                        get: { Int(round(zone.height * 100)) },
                                        set: { newValue in
                                            let clamped = Double(max(5, min(95, newValue))) / 100.0
                                            setZoneHeight(zone, to: clamped)
                                        }
                                    ), format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(size: 11, design: .monospaced))
                                    .frame(width: 44)
                                    Text("%")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
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
                    } else {
                        Text("Tap a zone in the preview to select it")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(8)
                    }
                }

                // Presets
                VStack(alignment: .leading, spacing: 6) {
                    Text("Start From Preset")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        Button("2 Columns") { applyPreset(columns: 2) }
                        Button("3 Columns") { applyPreset(columns: 3) }
                        Button("2\u{00d7}2 Grid") { applyGridPreset() }
                        Button("Top + Bottom") { applyTopBottomPreset() }
                    }
                    .font(.system(size: 11))
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

    // MARK: - Edge Detection & Resizing

    private func findDraggableEdges() -> [DraggableEdge] {
        var edges: [DraggableEdge] = []
        let tolerance = 0.001

        // Vertical edges (shared x positions between zones)
        var xPositions = Set<Int>()
        for zone in zones {
            let rightEdge = zone.x + zone.width
            if rightEdge > tolerance && rightEdge < 1.0 - tolerance {
                xPositions.insert(Int(round(rightEdge * 10000)))
            }
        }

        for xInt in xPositions.sorted() {
            let xPos = Double(xInt) / 10000.0
            let leftZones = zones.filter { abs($0.x + $0.width - xPos) < tolerance }
            let rightZones = zones.filter { abs($0.x - xPos) < tolerance }

            if !leftZones.isEmpty && !rightZones.isEmpty {
                let allY = (leftZones + rightZones).flatMap { [$0.y, $0.y + $0.height] }
                edges.append(DraggableEdge(
                    isVertical: true,
                    position: xPos,
                    rangeStart: allY.min() ?? 0,
                    rangeEnd: allY.max() ?? 1
                ))
            }
        }

        // Horizontal edges (shared y positions between zones)
        var yPositions = Set<Int>()
        for zone in zones {
            let bottomEdge = zone.y + zone.height
            if bottomEdge > tolerance && bottomEdge < 1.0 - tolerance {
                yPositions.insert(Int(round(bottomEdge * 10000)))
            }
        }

        for yInt in yPositions.sorted() {
            let yPos = Double(yInt) / 10000.0
            let topZones = zones.filter { abs($0.y + $0.height - yPos) < tolerance }
            let bottomZones = zones.filter { abs($0.y - yPos) < tolerance }

            if !topZones.isEmpty && !bottomZones.isEmpty {
                let allX = (topZones + bottomZones).flatMap { [$0.x, $0.x + $0.width] }
                edges.append(DraggableEdge(
                    isVertical: false,
                    position: yPos,
                    rangeStart: allX.min() ?? 0,
                    rangeEnd: allX.max() ?? 1
                ))
            }
        }

        return edges
    }

    private func adjustedZones(from original: [LayoutZone], edge: DraggableEdge, to newPosition: Double) -> [LayoutZone] {
        let minSize = 0.05
        let tolerance = 0.001

        // Compute clamping bounds from affected zones
        var minPos = minSize
        var maxPos = 1.0 - minSize

        if edge.isVertical {
            for zone in original {
                if abs(zone.x + zone.width - edge.position) < tolerance {
                    minPos = max(minPos, zone.x + minSize)
                }
                if abs(zone.x - edge.position) < tolerance {
                    maxPos = min(maxPos, zone.x + zone.width - minSize)
                }
            }
        } else {
            for zone in original {
                if abs(zone.y + zone.height - edge.position) < tolerance {
                    minPos = max(minPos, zone.y + minSize)
                }
                if abs(zone.y - edge.position) < tolerance {
                    maxPos = min(maxPos, zone.y + zone.height - minSize)
                }
            }
        }

        let pos = max(minPos, min(maxPos, newPosition))
        var result = original

        if edge.isVertical {
            for i in result.indices {
                if abs(result[i].x + result[i].width - edge.position) < tolerance {
                    result[i].width = pos - result[i].x
                }
                if abs(result[i].x - edge.position) < tolerance {
                    let right = result[i].x + result[i].width
                    result[i].x = pos
                    result[i].width = right - pos
                }
            }
        } else {
            for i in result.indices {
                if abs(result[i].y + result[i].height - edge.position) < tolerance {
                    result[i].height = pos - result[i].y
                }
                if abs(result[i].y - edge.position) < tolerance {
                    let bottom = result[i].y + result[i].height
                    result[i].y = pos
                    result[i].height = bottom - pos
                }
            }
        }

        return result
    }

    private func setZoneWidth(_ zone: LayoutZone, to newWidth: Double) {
        let tolerance = 0.001
        let rightEdge = zone.x + zone.width
        let leftEdge = zone.x

        let hasRightNeighbor = zones.contains { abs($0.x - rightEdge) < tolerance && $0.id != zone.id }
        let hasLeftNeighbor = zones.contains { abs($0.x + $0.width - leftEdge) < tolerance && $0.id != zone.id }

        if hasRightNeighbor {
            let edge = DraggableEdge(isVertical: true, position: rightEdge, rangeStart: zone.y, rangeEnd: zone.y + zone.height)
            zones = adjustedZones(from: zones, edge: edge, to: zone.x + newWidth)
        } else if hasLeftNeighbor {
            let edge = DraggableEdge(isVertical: true, position: leftEdge, rangeStart: zone.y, rangeEnd: zone.y + zone.height)
            zones = adjustedZones(from: zones, edge: edge, to: zone.x + zone.width - newWidth)
        } else if let idx = zones.firstIndex(where: { $0.id == zone.id }) {
            zones[idx].width = min(1.0 - zones[idx].x, max(0.05, newWidth))
        }
    }

    private func setZoneHeight(_ zone: LayoutZone, to newHeight: Double) {
        let tolerance = 0.001
        let bottomEdge = zone.y + zone.height
        let topEdge = zone.y

        let hasBottomNeighbor = zones.contains { abs($0.y - bottomEdge) < tolerance && $0.id != zone.id }
        let hasTopNeighbor = zones.contains { abs($0.y + $0.height - topEdge) < tolerance && $0.id != zone.id }

        if hasBottomNeighbor {
            let edge = DraggableEdge(isVertical: false, position: bottomEdge, rangeStart: zone.x, rangeEnd: zone.x + zone.width)
            zones = adjustedZones(from: zones, edge: edge, to: zone.y + newHeight)
        } else if hasTopNeighbor {
            let edge = DraggableEdge(isVertical: false, position: topEdge, rangeStart: zone.x, rangeEnd: zone.x + zone.width)
            zones = adjustedZones(from: zones, edge: edge, to: zone.y + zone.height - newHeight)
        } else if let idx = zones.firstIndex(where: { $0.id == zone.id }) {
            zones[idx].height = min(1.0 - zones[idx].y, max(0.05, newHeight))
        }
    }

    // MARK: - Actions

    private func splitZone(_ zone: LayoutZone, horizontal: Bool) {
        guard let idx = zones.firstIndex(where: { $0.id == zone.id }) else { return }

        let z = zones[idx]
        zones.remove(at: idx)

        if horizontal {
            let left = LayoutZone(id: UUID(), name: "\(z.name) L", x: z.x, y: z.y, width: z.width / 2, height: z.height)
            let right = LayoutZone(id: UUID(), name: "\(z.name) R", x: z.x + z.width / 2, y: z.y, width: z.width / 2, height: z.height)
            zones.insert(contentsOf: [left, right], at: idx)
            selectedZoneId = left.id
        } else {
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
