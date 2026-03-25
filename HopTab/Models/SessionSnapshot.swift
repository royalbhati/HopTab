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

    /// Compute a key representing the current display configuration.
    /// Example: "1440x900" (laptop only), "1440x900+2560x1440" (laptop + external).
    static var currentDisplayConfigKey: String {
        let screens = NSScreen.screens
            .sorted { $0.frame.origin.x < $1.frame.origin.x }
            .map { "\(Int($0.frame.width))x\(Int($0.frame.height))" }
        return screens.joined(separator: "+")
    }
}
