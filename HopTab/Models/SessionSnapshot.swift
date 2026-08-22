import AppKit
import Foundation
import CoreGraphics

struct WindowSnapshot: Codable, Equatable {
    let bundleIdentifier: String
    let windowTitle: String
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let isMinimized: Bool
    let zIndex: Int

    var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(bundleIdentifier: String, windowTitle: String, frame: CGRect, isMinimized: Bool, zIndex: Int) {
        self.bundleIdentifier = bundleIdentifier
        self.windowTitle = windowTitle
        self.x = frame.origin.x
        self.y = frame.origin.y
        self.width = frame.size.width
        self.height = frame.size.height
        self.isMinimized = isMinimized
        self.zIndex = zIndex
    }
}

struct SessionSnapshot: Codable, Equatable {
    let profileId: UUID
    let capturedAt: Date
    var windows: [WindowSnapshot]
    /// Display configuration when this snapshot was taken. nil = legacy (pre-display-awareness).
    var displayConfigKey: String?

    /// Compute a key representing the current display configuration, based on
    /// each display's stable hardware UUID (sorted). Unlike the old
    /// resolution-based key, this survives resolution changes and doesn't
    /// collide when two different setups happen to share resolutions.
    /// Falls back to the legacy key if no display UUID can be resolved.
    static var currentDisplayConfigKey: String {
        let uuids = NSScreen.screens
            .compactMap { screen -> String? in
                guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                      let cfUUID = CGDisplayCreateUUIDFromDisplayID(displayID)?.takeRetainedValue()
                else { return nil }
                return CFUUIDCreateString(nil, cfUUID) as String
            }
            .sorted()
        guard !uuids.isEmpty else { return legacyDisplayConfigKey }
        return uuids.joined(separator: "+")
    }

    /// Legacy resolution-based key, kept so snapshots saved before the
    /// UUID-based key aren't orphaned. Example: "1440x900+2560x1440".
    static var legacyDisplayConfigKey: String {
        let screens = NSScreen.screens
            .sorted { $0.frame.origin.x < $1.frame.origin.x }
            .map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }
        return screens.joined(separator: "+")
    }
}
