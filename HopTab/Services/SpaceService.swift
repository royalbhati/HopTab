import AppKit

/// Wraps private CGS APIs to get the current macOS Space (desktop) ID.
/// Space IDs are session-local integers — they can change after reboot
/// or when Spaces are added/removed.
enum SpaceService {

    /// Returns the numeric ID of the currently active Space, or nil if
    /// the private API is unavailable.
    static var currentSpaceId: Int? {
        let conn = CGSMainConnectionID()
        guard conn > 0 else { return nil }
        let spaceId = CGSGetActiveSpace(conn)
        guard spaceId > 0 else { return nil }
        return spaceId
    }

    /// Returns the stable UUID string of the currently active Space, or nil
    /// if the private APIs are unavailable. Unlike numeric Space IDs, these
    /// UUIDs survive reboots, so they're safe to persist.
    static var currentSpaceUUID: String? {
        guard let id = currentSpaceId else { return nil }
        return uuid(forSpaceId: id)
    }

    /// All Spaces across all displays as (session-local numeric ID, stable UUID)
    /// pairs. Returns [] if the private API is unavailable.
    static var allSpaces: [(id: Int, uuid: String)] {
        let conn = CGSMainConnectionID()
        guard conn > 0,
              let displays = CGSCopyManagedDisplaySpaces(conn)?.takeRetainedValue() as? [[String: Any]]
        else { return [] }

        var result: [(id: Int, uuid: String)] = []
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            for space in spaces {
                guard let uuid = space["uuid"] as? String, !uuid.isEmpty else { continue }
                let id = (space["ManagedSpaceID"] as? Int) ?? (space["id64"] as? Int) ?? 0
                guard id > 0 else { continue }
                result.append((id: id, uuid: uuid))
            }
        }
        return result
    }

    /// Look up the stable UUID for a session-local numeric Space ID.
    static func uuid(forSpaceId id: Int) -> String? {
        allSpaces.first { $0.id == id }?.uuid
    }

    /// Look up the session-local numeric ID for a stable Space UUID.
    static func spaceId(forUUID uuid: String) -> Int? {
        allSpaces.first { $0.uuid == uuid }?.id
    }

    // MARK: - Window → Space Movement

    /// The Space a window currently lives on, or nil if unknown.
    static func spaceId(forWindow windowID: CGWindowID) -> Int? {
        let conn = CGSMainConnectionID()
        guard conn > 0 else { return nil }
        let windowIDs = [NSNumber(value: windowID)] as CFArray
        guard let spaces = CGSCopySpacesForWindows(conn, kCGSAllSpacesMask, windowIDs)?
                .takeRetainedValue() as? [Int],
              let first = spaces.first, first > 0
        else { return nil }
        return first
    }

    /// Move windows to a Space by its session-local numeric ID.
    /// Works without disabling SIP (same call yabai uses for window→space),
    /// but macOS 14.5+ can restrict it — success is verified by re-querying
    /// each window's Space after the call.
    /// Returns true only when every window verifiably landed on the target Space.
    @discardableResult
    static func moveWindows(_ windowIDs: [CGWindowID], toSpaceId spaceId: Int) -> Bool {
        let conn = CGSMainConnectionID()
        guard conn > 0, !windowIDs.isEmpty else { return false }
        // Verify the target Space actually exists before calling the private API.
        guard allSpaces.contains(where: { $0.id == spaceId }) else {
            NSLog("[SpaceService] moveWindows: Space %d does not exist — no-op", spaceId)
            return false
        }
        let cfWindows = windowIDs.map { NSNumber(value: $0) } as CFArray
        CGSMoveWindowsToManagedSpace(conn, cfWindows, UInt64(spaceId))

        // Detect silent restriction (macOS 14.5+): re-query each window's Space.
        let allMoved = windowIDs.allSatisfy { self.spaceId(forWindow: $0) == spaceId }
        if !allMoved {
            NSLog("[SpaceService] moveWindows: verification failed — CGSMoveWindowsToManagedSpace appears restricted on this macOS version")
        }
        return allMoved
    }

    /// UUID-based convenience for `moveWindows(_:toSpaceId:)`.
    @discardableResult
    static func moveWindows(_ windowIDs: [CGWindowID], toSpaceUUID uuid: String) -> Bool {
        guard let id = spaceId(forUUID: uuid) else {
            NSLog("[SpaceService] moveWindows: no Space with UUID %@ — no-op", uuid)
            return false
        }
        return moveWindows(windowIDs, toSpaceId: id)
    }

    // MARK: - Direct Space Switching (requires reduced SIP)

    /// Switch the display hosting the given Space directly to that Space,
    /// bypassing the Mission Control animation / keyboard emulation.
    /// Only effective when SIP is reduced; returns false on any failure so
    /// callers can fall back to default behavior.
    @discardableResult
    static func switchToSpace(spaceId target: Int) -> Bool {
        let conn = CGSMainConnectionID()
        guard conn > 0,
              let displays = CGSCopyManagedDisplaySpaces(conn)?.takeRetainedValue() as? [[String: Any]]
        else { return false }

        // Find the display identifier hosting the target Space.
        var displayIdentifier: String?
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let hosts = spaces.contains { space in
                ((space["ManagedSpaceID"] as? Int) ?? (space["id64"] as? Int) ?? 0) == target
            }
            if hosts {
                displayIdentifier = display["Display Identifier"] as? String
                break
            }
        }
        guard let displayIdentifier else {
            NSLog("[SpaceService] switchToSpace: no display hosts Space %d — no-op", target)
            return false
        }

        CGSManagedDisplaySetCurrentSpace(conn, displayIdentifier as CFString, UInt64(target))
        let switched = currentSpaceId == target
        if !switched {
            NSLog("[SpaceService] switchToSpace: CGSManagedDisplaySetCurrentSpace had no effect (SIP likely enabled)")
        }
        return switched
    }

    // MARK: - SIP Detection

    enum SIPStatus {
        case enabled
        case partiallyDisabled
        case disabled
        case unknown
    }

    /// Detected SIP status, from `/usr/bin/csrutil status`. Queried once and
    /// cached for the session (SIP can only change from Recovery mode anyway).
    static var sipStatus: SIPStatus {
        if let cached = cachedSIPStatus { return cached }
        let status = querySIPStatus()
        cachedSIPStatus = status
        return status
    }

    private static var cachedSIPStatus: SIPStatus?

    private static func querySIPStatus() -> SIPStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/csrutil")
        process.arguments = ["status"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            NSLog("[SpaceService] csrutil failed to launch: %@", error.localizedDescription)
            return .unknown
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let output = String(data: data, encoding: .utf8)?.lowercased(), !output.isEmpty else {
            return .unknown
        }
        // "Custom Configuration" = partially disabled (e.g. csrutil enable --without ...)
        if output.contains("custom configuration") { return .partiallyDisabled }
        if output.contains("status: disabled") || output.contains("is disabled") { return .disabled }
        if output.contains("status: enabled") || output.contains("is enabled") { return .enabled }
        return .unknown
    }
}

// MARK: - Private CGS declarations

/// Connection ID for the current login session.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

/// Returns the Space ID of the currently active desktop.
@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: Int32) -> Int

/// Returns an array of display dictionaries; each contains a "Spaces" array of
/// space dictionaries with "uuid" (String) and "ManagedSpaceID"/"id64" (Int).
/// This is a Copy function — the caller owns the returned array.
@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?

/// Returns the Space IDs containing the given windows. Copy function —
/// the caller owns the returned array.
@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ cid: Int32, _ mask: UInt32, _ windowIDs: CFArray) -> Unmanaged<CFArray>?

/// Include current, other, and fullscreen Spaces in the lookup.
private let kCGSAllSpacesMask: UInt32 = 0x7

/// Moves windows to a managed Space. Same call yabai uses for window→space;
/// works with SIP fully enabled, but can be silently restricted on 14.5+.
@_silgen_name("CGSMoveWindowsToManagedSpace")
private func CGSMoveWindowsToManagedSpace(_ cid: Int32, _ windows: CFArray, _ space: UInt64)

/// Switches a display directly to a Space, bypassing Mission Control animation.
/// Only effective when SIP is reduced.
@_silgen_name("CGSManagedDisplaySetCurrentSpace")
private func CGSManagedDisplaySetCurrentSpace(_ cid: Int32, _ display: CFString, _ space: UInt64)
