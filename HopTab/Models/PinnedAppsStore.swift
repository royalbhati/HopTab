import Foundation
import Combine

/// Optional launch orchestration options for a pinned app within a profile.
/// Stored as a sidecar (keyed by profileId + bundleIdentifier) so existing
/// persisted profiles decode unchanged; all fields optional.
struct LaunchOptions: Codable, Equatable {
    /// Launch group ordering — lower launches first; nil = default (last) group.
    var launchPriority: Int?
    /// Seconds to wait after the previous group finished before launching this app.
    var launchDelay: TimeInterval?
    /// URLs or file paths to open in this app once it's ready on restore.
    var openURLs: [String]?
    /// Pinned for switching but excluded from restore launch + positioning.
    var skipOnRestore: Bool?

    /// True when no option is meaningfully set (entry can be pruned).
    var isEmpty: Bool {
        launchPriority == nil
            && launchDelay == nil
            && (openURLs?.isEmpty ?? true)
            && !(skipOnRestore ?? false)
    }
}

final class PinnedAppsStore: ObservableObject {
    private static let profilesKey = "profiles"
    private static let launchOptionsKey = "profileLaunchOptions"
    private static let activeProfileKey = "activeProfileId"
    private static let spaceMappingKey = "spaceToProfile"
    private static let legacyKey = "pinnedApps"
    private static let snapshotsKey = "sessionSnapshots"
    private static let moveWindowsToSpaceKey = "profileMoveWindowsToSpace"
    private static let customTemplatesKey = "customLayoutTemplates"

    @Published private(set) var profiles: [Profile] = []
    @Published private(set) var activeProfileId: UUID?
    /// Multiple snapshots per profile — one per display configuration.
    @Published private(set) var snapshots: [UUID: [SessionSnapshot]] = [:]
    @Published private(set) var customTemplates: [LayoutTemplate] = []
    /// Launch orchestration options: profileId → (bundleIdentifier → options).
    @Published private(set) var launchOptions: [UUID: [String: LaunchOptions]] = [:]
    /// Per-profile "move windows to assigned Space" opt-in. Sidecar (like
    /// LaunchOptions) so existing persisted profiles decode unchanged.
    @Published private(set) var moveWindowsToSpace: Set<UUID> = []

    /// All available templates (built-in + custom).
    var allTemplates: [LayoutTemplate] {
        LayoutTemplate.builtInTemplates + customTemplates
    }

    /// Maps stable Space UUID (String) → Profile ID. Persisted in UserDefaults.
    /// Space UUIDs survive reboots, unlike the session-local Int IDs this
    /// mapping used to be keyed by (legacy Int keys are migrated on load).
    @Published var spaceMapping: [String: UUID] = [:]

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
        if launchOptions.removeValue(forKey: id) != nil {
            persistLaunchOptions()
        }
        if moveWindowsToSpace.remove(id) != nil {
            persistMoveWindowsToSpace()
        }
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
        guard let spaceUUID = SpaceService.currentSpaceUUID else { return }
        // Remove any existing mapping for this profile (one profile per space)
        spaceMapping = spaceMapping.filter { $0.value != profileId }
        spaceMapping[spaceUUID] = profileId
        save()
    }

    /// Remove the Space mapping for a profile.
    func unassignProfileFromSpace(profileId: UUID) {
        spaceMapping = spaceMapping.filter { $0.value != profileId }
        save()
    }

    /// Look up which profile is mapped to a given session-local Space ID.
    func profileForSpace(_ spaceId: Int) -> UUID? {
        guard let spaceUUID = SpaceService.uuid(forSpaceId: spaceId),
              let profileId = spaceMapping[spaceUUID],
              profiles.contains(where: { $0.id == profileId })
        else { return nil }
        return profileId
    }

    /// Returns the session-local Space ID currently assigned to a profile,
    /// if the mapped Space still exists.
    func spaceForProfile(_ profileId: UUID) -> Int? {
        guard let spaceUUID = spaceMapping.first(where: { $0.value == profileId })?.key else { return nil }
        return SpaceService.spaceId(forUUID: spaceUUID)
    }

    /// Whether a profile moves its apps' windows to its assigned Space on switch.
    func movesWindowsToAssignedSpace(_ profileId: UUID) -> Bool {
        moveWindowsToSpace.contains(profileId)
    }

    /// Enable/disable "move windows to assigned Space" for a profile.
    func setMoveWindowsToAssignedSpace(profileId: UUID, enabled: Bool) {
        if enabled {
            moveWindowsToSpace.insert(profileId)
        } else {
            moveWindowsToSpace.remove(profileId)
        }
        persistMoveWindowsToSpace()
    }

    private func persistMoveWindowsToSpace() {
        UserDefaults.standard.set(moveWindowsToSpace.map { $0.uuidString }, forKey: Self.moveWindowsToSpaceKey)
    }

    private func loadMoveWindowsToSpace() {
        guard let strings = UserDefaults.standard.stringArray(forKey: Self.moveWindowsToSpaceKey) else { return }
        moveWindowsToSpace = Set(strings.compactMap(UUID.init(uuidString:)))
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
        // Fall back to the legacy resolution-based key so snapshots saved
        // before the UUID-based config key aren't orphaned
        let legacyConfig = SessionSnapshot.legacyDisplayConfigKey
        if let match = list.first(where: { $0.displayConfigKey == legacyConfig }) {
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
        guard let data = UserDefaults.standard.data(forKey: Self.snapshotsKey) else { return }
        // Try new format: [UUID: [SessionSnapshot]]
        if let decoded = try? JSONDecoder().decode([UUID: [SessionSnapshot]].self, from: data) {
            snapshots = decoded
            return
        }
        // Migrate old format: [UUID: SessionSnapshot] → [UUID: [SessionSnapshot]]
        if let legacy = try? JSONDecoder().decode([UUID: SessionSnapshot].self, from: data) {
            snapshots = legacy.mapValues { [$0] }
            persistSnapshots()
            return
        }
        // Both decodes failed — preserve the raw blob before it can be overwritten.
        Self.backupCorruptData(data, label: "sessionSnapshots")
    }

    // MARK: - Launch Options

    /// Launch options for an app in a profile, or nil if none are set.
    func launchOptions(profileId: UUID, bundleId: String) -> LaunchOptions? {
        launchOptions[profileId]?[bundleId]
    }

    /// Set (or replace) the full launch options for an app in a profile.
    /// Passing nil — or options where `isEmpty` is true — clears the entry.
    func setLaunchOptions(profileId: UUID, bundleId: String, options: LaunchOptions?) {
        var forProfile = launchOptions[profileId] ?? [:]
        if let options, !options.isEmpty {
            forProfile[bundleId] = options
        } else {
            forProfile.removeValue(forKey: bundleId)
        }
        launchOptions[profileId] = forProfile.isEmpty ? nil : forProfile
        persistLaunchOptions()
    }

    /// Convenience field-level setter: updates only the provided fields,
    /// leaving others as-is. Use `setLaunchOptions(profileId:bundleId:options:)`
    /// with nil to clear everything.
    func setLaunchOptions(
        profileId: UUID,
        bundleId: String,
        launchPriority: Int?? = nil,
        launchDelay: TimeInterval?? = nil,
        openURLs: [String]?? = nil,
        skipOnRestore: Bool?? = nil
    ) {
        var options = launchOptions(profileId: profileId, bundleId: bundleId) ?? LaunchOptions()
        if let launchPriority { options.launchPriority = launchPriority }
        if let launchDelay { options.launchDelay = launchDelay }
        if let openURLs { options.openURLs = openURLs?.isEmpty == true ? nil : openURLs }
        if let skipOnRestore { options.skipOnRestore = (skipOnRestore == true) ? true : nil }
        setLaunchOptions(profileId: profileId, bundleId: bundleId, options: options)
    }

    /// Remove all launch options for an app in a profile.
    func clearLaunchOptions(profileId: UUID, bundleId: String) {
        setLaunchOptions(profileId: profileId, bundleId: bundleId, options: nil)
    }

    private func persistLaunchOptions() {
        if let data = try? JSONEncoder().encode(launchOptions) {
            UserDefaults.standard.set(data, forKey: Self.launchOptionsKey)
        }
    }

    private func loadLaunchOptions() {
        guard let data = UserDefaults.standard.data(forKey: Self.launchOptionsKey) else { return }
        if let decoded = try? JSONDecoder().decode([UUID: [String: LaunchOptions]].self, from: data) {
            launchOptions = decoded
        } else {
            // Decode failed — preserve the raw blob before it can be overwritten.
            Self.backupCorruptData(data, label: "profileLaunchOptions")
        }
    }

    // MARK: - Sticky Note

    func setStickyNote(profileId: UUID, note: String?) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        let isEmpty = note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        profiles[idx].stickyNote = isEmpty ? nil : note
        save()
    }

    // MARK: - Browser profile

    func setBrowserProfile(profileId: UUID, _ browserProfile: BrowserProfile?) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[idx].browserProfile = browserProfile
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
        guard let data = UserDefaults.standard.data(forKey: Self.customTemplatesKey) else { return }
        if let decoded = try? JSONDecoder().decode([LayoutTemplate].self, from: data) {
            customTemplates = decoded
        } else {
            // Decode failed — preserve the raw blob before it can be overwritten.
            Self.backupCorruptData(data, label: "customLayoutTemplates")
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
        guard let profileId = activeProfileId else { return }
        add(app, toProfile: profileId)
    }

    func remove(bundleIdentifier: String) {
        guard let profileId = activeProfileId else { return }
        remove(bundleIdentifier: bundleIdentifier, fromProfile: profileId)
    }

    /// Pin `app` into any profile, not just the active one. Used by the
    /// switcher's number keys so a profile can be built without opening
    /// Settings. No-op if the app is already pinned there.
    func add(_ app: PinnedApp, toProfile profileId: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        guard !profiles[idx].pinnedApps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
        var newApp = app
        newApp.sortOrder = profiles[idx].pinnedApps.count
        profiles[idx].pinnedApps.append(newApp)
        save()
    }

    func remove(bundleIdentifier: String, fromProfile profileId: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
        profiles[idx].pinnedApps.removeAll { $0.bundleIdentifier == bundleIdentifier }
        reindex(profileIndex: idx)
        // Drop any launch options tied to the unpinned app
        clearLaunchOptions(profileId: profileId, bundleId: bundleIdentifier)
        save()
    }

    func isPinned(_ bundleIdentifier: String, inProfile profileId: UUID) -> Bool {
        profiles.first { $0.id == profileId }?
            .pinnedApps.contains { $0.bundleIdentifier == bundleIdentifier } ?? false
    }

    /// Toggle membership of an app in a specific profile. Returns `true` if
    /// the app is pinned there after the call.
    @discardableResult
    func togglePin(bundleIdentifier: String, displayName: String, inProfile profileId: UUID) -> Bool {
        if isPinned(bundleIdentifier, inProfile: profileId) {
            remove(bundleIdentifier: bundleIdentifier, fromProfile: profileId)
            return false
        }
        add(PinnedApp(bundleIdentifier: bundleIdentifier, displayName: displayName, sortOrder: 0), toProfile: profileId)
        return true
    }

    func move(from source: IndexSet, to destination: Int) {
        guard let profileId = activeProfileId else { return }
        move(from: source, to: destination, inProfile: profileId)
    }

    func move(from source: IndexSet, to destination: Int, inProfile profileId: UUID) {
        guard let idx = profiles.firstIndex(where: { $0.id == profileId }) else { return }
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

    /// Assign an app to a specific display (by display name), or nil to clear.
    func setDisplayAssignment(bundleIdentifier: String, displayName: String?) {
        guard let profileId = activeProfileId else { return }
        setDisplayAssignment(bundleIdentifier: bundleIdentifier, displayName: displayName, inProfile: profileId)
    }

    func setDisplayAssignment(bundleIdentifier: String, displayName: String?, inProfile profileId: UUID) {
        guard let profileIdx = profiles.firstIndex(where: { $0.id == profileId }),
              let appIdx = profiles[profileIdx].pinnedApps.firstIndex(where: { $0.bundleIdentifier == bundleIdentifier })
        else { return }
        profiles[profileIdx].pinnedApps[appIdx].assignedDisplay = displayName
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
        // Persist space mapping as [String: String] (space UUID → profileId)
        let stringMap = spaceMapping.mapValues { $0.uuidString }
        UserDefaults.standard.set(stringMap, forKey: Self.spaceMappingKey)
    }

    private func load() {
        // Load session snapshots and custom templates
        loadSnapshots()
        loadCustomTemplates()
        loadLaunchOptions()
        loadMoveWindowsToSpace()

        // Load space mapping (keyed by stable space UUID; legacy Int keys migrated)
        loadSpaceMapping()

        // Try loading new profiles format
        if let data = UserDefaults.standard.data(forKey: Self.profilesKey) {
            do {
                let decoded = try JSONDecoder().decode([Profile].self, from: data)
                profiles = decoded
                if let idStr = UserDefaults.standard.string(forKey: Self.activeProfileKey),
                   let id = UUID(uuidString: idStr),
                   profiles.contains(where: { $0.id == id }) {
                    activeProfileId = id
                } else {
                    activeProfileId = profiles.first?.id
                }
                return
            } catch {
                // Decode failed — preserve the raw blob before any save()
                // below overwrites it, then continue with fresh state.
                Self.backupCorruptData(data, label: "profiles")
            }
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

    /// Load the space → profile mapping, migrating legacy Int-keyed entries
    /// (session-local Space IDs) to stable space UUID keys, and pruning
    /// entries whose Space no longer exists.
    private func loadSpaceMapping() {
        guard let stringMap = UserDefaults.standard.dictionary(forKey: Self.spaceMappingKey) as? [String: String] else {
            return
        }
        let liveSpaces = SpaceService.allSpaces
        let liveUUIDs = Set(liveSpaces.map { $0.uuid })

        var migrated: [String: UUID] = [:]
        for (key, profileStr) in stringMap {
            guard let profileId = UUID(uuidString: profileStr) else { continue }
            if let legacySpaceId = Int(key) {
                // Legacy Int-keyed entry. Space IDs are session-local, so this
                // is best-effort: map to a UUID if the ID still resolves,
                // otherwise drop the stale entry.
                if let uuid = liveSpaces.first(where: { $0.id == legacySpaceId })?.uuid {
                    migrated[uuid] = profileId
                }
            } else {
                // UUID-keyed entry. Prune it if the Space no longer exists —
                // but only when we can actually enumerate spaces, so a CGS
                // failure doesn't wipe valid mappings.
                if liveUUIDs.isEmpty || liveUUIDs.contains(key) {
                    migrated[key] = profileId
                }
            }
        }
        spaceMapping = migrated

        // Persist the migrated/pruned form so legacy keys don't linger.
        if migrated.count != stringMap.count || stringMap.keys.contains(where: { Int($0) != nil }) {
            UserDefaults.standard.set(migrated.mapValues { $0.uuidString }, forKey: Self.spaceMappingKey)
        }
    }

    /// Preserve a raw UserDefaults blob that failed to decode, so a bad decode
    /// never silently destroys user data. Keeps at most 3 backups (oldest evicted).
    private static let backupIndexKey = "corruptDataBackups"
    private static func backupCorruptData(_ data: Data, label: String) {
        let defaults = UserDefaults.standard
        var keys = defaults.stringArray(forKey: backupIndexKey) ?? []
        let stamp = ISO8601DateFormatter().string(from: Date())
        let key = "\(label)Backup_\(stamp)"
        defaults.set(data, forKey: key)
        keys.append(key)
        while keys.count > 3 {
            defaults.removeObject(forKey: keys.removeFirst())
        }
        defaults.set(keys, forKey: backupIndexKey)
        NSLog("[PinnedAppsStore] Failed to decode '%@' — raw data preserved under '%@'", label, key)
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
