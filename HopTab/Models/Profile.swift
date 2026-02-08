import Foundation

struct Profile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var pinnedApps: [PinnedApp]

    init(id: UUID = UUID(), name: String, pinnedApps: [PinnedApp] = []) {
        self.id = id
        self.name = name
        self.pinnedApps = pinnedApps
    }
}
