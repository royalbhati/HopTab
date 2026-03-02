import Foundation

struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var pinnedApps: [PinnedApp]
    var hotkey: CustomShortcut?

    init(id: UUID = UUID(), name: String, pinnedApps: [PinnedApp] = [], hotkey: CustomShortcut? = nil) {
        self.id = id
        self.name = name
        self.pinnedApps = pinnedApps
        self.hotkey = hotkey
    }
}
