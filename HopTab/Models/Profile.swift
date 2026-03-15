import Foundation

struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var pinnedApps: [PinnedApp]
    var hotkey: CustomShortcut?
    var stickyNote: String?
    var layoutBinding: LayoutBinding?

    init(id: UUID = UUID(), name: String, pinnedApps: [PinnedApp] = [], hotkey: CustomShortcut? = nil, stickyNote: String? = nil, layoutBinding: LayoutBinding? = nil) {
        self.id = id
        self.name = name
        self.pinnedApps = pinnedApps
        self.hotkey = hotkey
        self.stickyNote = stickyNote
        self.layoutBinding = layoutBinding
    }
}
