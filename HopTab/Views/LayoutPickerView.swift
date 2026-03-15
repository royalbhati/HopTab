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
                            .onTapGesture {
                                withAnimation(.spring(response: 0.3)) {
                                    if selectedTemplateId == template.id {
                                        // Deselect
                                        selectedTemplateId = nil
                                    } else {
                                        // Just preview — don't clear the stored binding
                                        selectedTemplateId = template.id
                                    }
                                }
                            }
                        }
                    }
                    .padding(6)
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
                .menuStyle(.borderlessButton)
                .fixedSize()
                Spacer()
            }
        }
        .padding(.vertical, 3)
    }
}
