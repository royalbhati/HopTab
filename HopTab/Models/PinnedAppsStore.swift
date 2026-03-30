import Foundation
import Combine

final class PinnedAppsStore: ObservableObject {
    private static let profilesKey = "profiles"
    private static let activeProfileKey = "activeProfileId"
    private static let spaceMappingKey = "spaceToProfile"
    private static let legacyKey = "pinnedApps"
    private static let snapshotsKey = "sessionSnapshots"
    private static let customTemplatesKey = "customLayoutTemplates"

    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeProfileId: UUID?
    /// Multiple snapshots per profile — one per display configuration.
    @Published private(set) var snapshots: [UUID: [SessionSnapshot]] = [:]
    @Published private(set) var customTemplates: [LayoutTemplate] = []

    /// All available templates (built-in + custom).
    var allTemplates: [LayoutTemplate] {
        LayoutTemplate.builtInTemplates + customTemplates
    }

    /// Maps Space ID (Int) → Profile ID (UUID string). Persisted in UserDefaults.
    @Published var spaceMapping: [Int: UUID] = [:]

    /// The currently active profile's pinned apps (convenience for hotkey/overlay).
    var apps: [PinnedApp] {
        activeProfile?.pinnedApps ?? []
    }

    var activeProfile: Profile? {
        profiles.first { $0.id == activeProfileId }
    }

    init() {
        load()
    }

    // MARK: - Profile CRUD

    func addProfile(name: String) {
        let profile = Profile(name: name)
        profiles.append(profile)
        if profiles.count == 1 {
            activeProfileId = profile.id
        }
        save()
    }

    /// Whether the user can create another profile (respects Pro limit).
    @MainActor
    var canAddProfile: Bool {
        ProFeatureGate.canCreateProfile(currentCount: profiles.count)
    }

    func renameProfile(id: UUID, to name: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].name = name
        save()
    }

    func deleteProfile(id: UUID) {
        profiles.removeAll { $0.id == id }
        spaceMapping = spaceMapping.filter { $0.value != id }
        if activeProfileId == id {
            activeProfileId = profiles.first?.id
        }
        save()
    }

    func setActiveProfile(id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileId = id
        save()
    }

    // MARK: - Space ↔ Profile Mapping

    /// Assign a profile to the current desktop Space.
    func assignProfileToCurrentSpace(profileId: UUID) {
        guard let spaceId = SpaceService.currentSpaceId else { return }
        // Remove any existing mapping for this profile (one profile per space)
        spaceMapping = spaceMapping.filter { $0.value != profileId }
        spaceMapping[spaceId] = profileId
        save()
    }

    /// Remove the Space mapping for a profile.
    func unassignProfileFromSpace(profileId: UUID) {
        spaceMapping = spaceMapping.filter { $0.value != profileId }
        save()
    }

    /// Look up which profile is mapped to a given Space ID.
    func profileForSpace(_ spaceId: Int) -> UUID? {
        guard let profileId = spaceMapping[spaceId],
              profiles.contains(where: { $0.id == profileId })
        else { return nil }
        return profileId
    }

    /// Returns the Space ID currently assigned to a profile, if any.
    func spaceForProfile(_ profileId: UUID) -> Int? {
        spaceMapping.first { $0.value == profileId }?.key
    }

    // MARK: - Session Snapshots

    func saveSnapshot(_ snapshot: SessionSnapshot) {
        var list = snapshots[snapshot.profileId] ?? []
        // Replace existing snapshot for the same display config, or append
        if let idx = list.firstIndex(where: { $0.displayConfigKey == snapshot.displayConfigKey }) {
            list[idx] = snapshot
        } else {
            list.append(snapshot)
        }
        snapshots[snapshot.profileId] = list
        persistSnapshots()
    }

    /// Returns the snapshot matching the current display configuration,
    /// falling back to a legacy snapshot (nil config key), or nil.
    func snapshot(for profileId: UUID) -> SessionSnapshot? {
        guard let list = snapshots[profileId], !list.isEmpty else { return nil }
        let currentConfig = SessionSnapshot.currentDisplayConfigKey
        // Prefer exact display config match
        if let match = list.first(where: { $0.displayConfigKey == currentConfig }) {
            return match
        }
        // Fall back to legacy snapshot (no display config)
        if let legacy = list.first(where: { $0.displayConfigKey == nil }) {
            return legacy
        }
        // Fall back to most recent snapshot
        return list.max(by: { $0.capturedAt < $1.capturedAt })
    }

    private func persistSnapshots() {
        if let data = try? JSONEncoder().encode(snapshots) {
            UserDefaults.standard.set(data, forKey: Self.snapshotsKey)
        }
    }

    private func loadSnapshots() {
        // Try new format: [UUID: [SessionSnapshot]]
        if let data = UserDefaults.standard.data(forKey: Self.snapshotsKey),
           let decoded = try? JSONDecoder().decode([UUID: [SessionSnapshot]].self, from: data) {
            snapshots = decoded
            return
        }
        // Migrate old format: [UUID: SessionSnapshot] → [UUID: [SessionSnapshot]]
        if let data = UserDefaults.standard.data(forKey: Self.snapshotsKey),
           let legacy = try? JSONDecoder().decode([UUID: SessionSnapshot].self, from: data) {
            snapshots = legacy.mapValues { [$0] }
            persistSnapshots()
        }
    }

    // MARK: - Sticky Note

    func setStickyNote(profileId: UUID, note: String?) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        let isEmpty = note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        profiles[idx].stickyNote = isEmpty ? nil : note
        save()
    }

    // MARK: - Layout Binding

    func setLayoutBinding(profileId: UUID, binding: LayoutBinding?) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[idx].layoutBinding = binding
        save()
    }

    func assignZone(profileId: UUID, templateId: UUID, zoneId: UUID, bundleIdentifier: String) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        if profiles[idx].layoutBinding == nil || profiles[idx].layoutBinding?.templateId != templateId {
            profiles[idx].layoutBinding = LayoutBinding(templateId: templateId, zoneAssignments: [:])
        }
        profiles[idx].layoutBinding?.zoneAssignments[zoneId] = bundleIdentifier
        save()
    }

    func unassignZone(profileId: UUID, zoneId: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[idx].layoutBinding?.zoneAssignments.removeValue(forKey: zoneId)
        save()
    }

    // MARK: - Custom Templates

    func addCustomTemplate(_ template: LayoutTemplate) {
        customTemplates.append(template)
        saveCustomTemplates()
    }

    func updateCustomTemplate(_ template: LayoutTemplate) {
        guard let idx = customTemplates.firstIndex(where: { $0.id == template.id }) else { return }
        customTemplates[idx] = template
        saveCustomTemplates()
    }

    func deleteCustomTemplate(id: UUID) {
        customTemplates.removeAll { $0.id == id }
        // Clear any profile bindings that reference this template
        for i in profiles.indices {
            if profiles[i].layoutBinding?.templateId == id {
                profiles[i].layoutBinding = nil
            }
        }
        saveCustomTemplates()
        save()
    }

    private func saveCustomTemplates() {
        if let data = try? JSONEncoder().encode(customTemplates) {
            UserDefaults.standard.set(data, forKey: Self.customTemplatesKey)
        }
    }

    private func loadCustomTemplates() {
        if let data = UserDefaults.standard.data(forKey: Self.customTemplatesKey),
           let decoded = try? JSONDecoder().decode([LayoutTemplate].self, from: data) {
            customTemplates = decoded
        }
    }

    // MARK: - Profile Hotkeys

    func setProfileHotkey(id: UUID, hotkey: CustomShortcut?) {
        guard let idx = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[idx].hotkey = hotkey
        save()
    }

    /// All profiles that have a hotkey configured.
    var profileHotkeys: [(UUID, CustomShortcut)] {
        profiles.compactMap { p in
            guard let hk = p.hotkey else { return nil }
            return (p.id, hk)
        }
    }

    // MARK: - Pin CRUD (operates on active profile)

    func add(_ app: PinnedApp) {
        guard let idx = activeProfileIndex else { return }
        guard !profiles[idx].pinnedApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
        var newApp = app
        newApp.sortOrder = profiles[idx].pinnedApps.count
        profiles[idx].pinnedApps.append(newApp)
        save()
    }

    func remove(bundleIdentifier: String) {
        guard let idx = activeProfileIndex else { return }
        profiles[idx].pinnedApps.removeAll { $0.bundleIdentifier == bundleIdentifier }
        reindex(profileIndex: idx)
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        guard let idx = activeProfileIndex else { return }
        profiles[idx].pinnedApps.move(fromOffsets: source, toOffset: destination)
        reindex(profileIndex: idx)
        save()
    }

    func moveToFront(bundleIdentifier: String) {
        guard let idx = activeProfileIndex,
              let appIdx = profiles[idx].pinnedApps.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier })
        else { return }
        let app = profiles[idx].pinnedApps.remove(at: appIdx)
        profiles[idx].pinnedApps.insert(app, at: 0)
        reindex(profileIndex: idx)
        save()
    }

    func isPinned(_ bundleIdentifier: String) -> Bool {
        activeProfile?.pinnedApps.contains { $0.bundleIdentifier == bundleIdentifier } ?? false
    }

    func togglePin(bundleIdentifier: String, displayName: String) {
        if isPinned(bundleIdentifier) {
            remove(bundleIdentifier: bundleIdentifier)
        } else {
            add(PinnedApp(bundleIdentifier: bundleIdentifier, displayName: displayName, sortOrder: 0))
        }
    }

    // MARK: - Persistence

    private func save() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.profilesKey)
        }
        if let id = activeProfileId {
            UserDefaults.standard.set(id.uuidString, forKey: Self.activeProfileKey)
        }
        // Persist space mapping as [String: String] (spaceId → profileId)
        let stringMap = Dictionary(uniqueKeysWithValues: spaceMapping.map { ("\($0.key)", $0.value.uuidString) })
        UserDefaults.standard.set(stringMap, forKey: Self.spaceMappingKey)
    }

    private func load() {
        // Load session snapshots and custom templates
        loadSnapshots()
        loadCustomTemplates()

        // Load space mapping
        if let stringMap = UserDefaults.standard.dictionary(forKey: Self.spaceMappingKey) as? [String: String] {
            spaceMapping = [:]
            for (spaceStr, profileStr) in stringMap {
                if let spaceId = Int(spaceStr), let profileId = UUID(uuidString: profileStr) {
                    spaceMapping[spaceId] = profileId
                }
            }
        }

        // Try loading new profiles format
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey),
           let decoded = try? JSONDecoder().decode([Profile].self, from: data) {
            profiles = decoded
            if let idStr = UserDefaults.standard.string(forKey: Self.activeProfileKey),
               let id = UUID(uuidString: idStr),
               profiles.contains(where: { $0.id == id }) {
                activeProfileId = id
            } else {
                activeProfileId = profiles.first?.id
            }
            return
        }

        // Migrate from legacy single-list format
        if let data = UserDefaults.standard.data(forKey: Self.legacyKey),
           let apps = try? JSONDecoder().decode([PinnedApp].self, from: data) {
            let defaultProfile = Profile(name: "Default", pinnedApps: apps.sorted { $0.sortOrder < $1.sortOrder })
            profiles = [defaultProfile]
            activeProfileId = defaultProfile.id
            save()
            UserDefaults.standard.removeObject(forKey: Self.legacyKey)
            return
        }

        // Fresh install — create a default profile
        let defaultProfile = Profile(name: "Default")
        profiles = [defaultProfile]
        activeProfileId = defaultProfile.id
        save()
    }

    private var activeProfileIndex: Int? {
        profiles.firstIndex { $0.id == activeProfileId }
    }

    private func reindex(profileIndex idx: Int) {
        for i in profiles[idx].pinnedApps.indices {
            profiles[idx].pinnedApps[i].sortOrder = i
        }
    }
}
