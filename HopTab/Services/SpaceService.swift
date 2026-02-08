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
}

// MARK: - Private CGS declarations

/// Connection ID for the current login session.
@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

/// Returns the Space ID of the currently active desktop.
@_silgen_name("CGSGetActiveSpace")
private func CGSGetActiveSpace(_ cid: Int32) -> Int
