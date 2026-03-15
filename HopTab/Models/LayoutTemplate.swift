import Foundation
import CoreGraphics

/// A named rectangular zone of the screen, expressed as fractions (0.0–1.0).
struct LayoutZone: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    /// Resolve to absolute pixels for the given screen frame.
    func frame(in screen: CGRect) -> CGRect {
        CGRect(
            x: screen.origin.x + screen.width * x,
            y: screen.origin.y + screen.height * y,
            width: screen.width * width,
            height: screen.height * height
        )
    }
}

/// A collection of zones that tile the screen.
struct LayoutTemplate: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var zones: [LayoutZone]
    var isBuiltIn: Bool

    init(id: UUID = UUID(), name: String, zones: [LayoutZone], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.zones = zones
        self.isBuiltIn = isBuiltIn
    }
}

/// Maps a layout template's zones to specific pinned apps within a profile.
struct LayoutBinding: Codable, Equatable {
    let templateId: UUID
    /// Maps zone ID -> bundle identifier of the app assigned to that zone.
    var zoneAssignments: [UUID: String]
}

// MARK: - Built-in Presets

extension LayoutTemplate {
    static let builtInTemplates: [LayoutTemplate] = [
        .leftRightHalf,
        .ideLayout,
        .threeColumn,
        .fullscreen,
        .grid2x2,
    ]

    static let leftRightHalf = LayoutTemplate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        name: "Left + Right",
        zones: [
            LayoutZone(id: UUID(uuidString: "00000001-0001-0000-0000-000000000001")!, name: "Left Half", x: 0, y: 0, width: 0.5, height: 1.0),
            LayoutZone(id: UUID(uuidString: "00000001-0001-0000-0000-000000000002")!, name: "Right Half", x: 0.5, y: 0, width: 0.5, height: 1.0),
        ],
        isBuiltIn: true
    )

    static let ideLayout = LayoutTemplate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        name: "IDE (60/40)",
        zones: [
            LayoutZone(id: UUID(uuidString: "00000002-0001-0000-0000-000000000001")!, name: "Main", x: 0, y: 0, width: 0.6, height: 1.0),
            LayoutZone(id: UUID(uuidString: "00000002-0001-0000-0000-000000000002")!, name: "Top Right", x: 0.6, y: 0, width: 0.4, height: 0.5),
            LayoutZone(id: UUID(uuidString: "00000002-0001-0000-0000-000000000003")!, name: "Bottom Right", x: 0.6, y: 0.5, width: 0.4, height: 0.5),
        ],
        isBuiltIn: true
    )

    static let threeColumn = LayoutTemplate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
        name: "Three Columns",
        zones: [
            LayoutZone(id: UUID(uuidString: "00000003-0001-0000-0000-000000000001")!, name: "Left", x: 0, y: 0, width: 1.0/3, height: 1.0),
            LayoutZone(id: UUID(uuidString: "00000003-0001-0000-0000-000000000002")!, name: "Center", x: 1.0/3, y: 0, width: 1.0/3, height: 1.0),
            LayoutZone(id: UUID(uuidString: "00000003-0001-0000-0000-000000000003")!, name: "Right", x: 2.0/3, y: 0, width: 1.0/3, height: 1.0),
        ],
        isBuiltIn: true
    )

    static let fullscreen = LayoutTemplate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
        name: "Fullscreen",
        zones: [
            LayoutZone(id: UUID(uuidString: "00000004-0001-0000-0000-000000000001")!, name: "Full", x: 0, y: 0, width: 1.0, height: 1.0),
        ],
        isBuiltIn: true
    )

    static let grid2x2 = LayoutTemplate(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000005")!,
        name: "Grid 2\u{00d7}2",
        zones: [
            LayoutZone(id: UUID(uuidString: "00000005-0001-0000-0000-000000000001")!, name: "Top Left", x: 0, y: 0, width: 0.5, height: 0.5),
            LayoutZone(id: UUID(uuidString: "00000005-0001-0000-0000-000000000002")!, name: "Top Right", x: 0.5, y: 0, width: 0.5, height: 0.5),
            LayoutZone(id: UUID(uuidString: "00000005-0001-0000-0000-000000000003")!, name: "Bottom Left", x: 0, y: 0.5, width: 0.5, height: 0.5),
            LayoutZone(id: UUID(uuidString: "00000005-0001-0000-0000-000000000004")!, name: "Bottom Right", x: 0.5, y: 0.5, width: 0.5, height: 0.5),
        ],
        isBuiltIn: true
    )
}
