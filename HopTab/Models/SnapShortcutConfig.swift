import Carbon.HIToolbox
import CoreGraphics
import Foundation

// MARK: - Display Grouping

/// One section of snap actions for the settings UI.
///
/// Exposed as data (`SnapShortcutConfig.actionGroups`) so the settings view can
/// render sections without hard-coding the case list; any `SnapDirection` that
/// is not named in a curated group is collected into a trailing "Other" group,
/// so a new enum case can never silently become unreachable in the UI.
struct SnapActionGroup: Identifiable, Equatable, Hashable {
    /// Stable identifier, safe to persist (e.g. a collapsed-section state).
    let id: String
    /// User-facing section title.
    let title: String
    /// Actions in this section, in display order.
    let directions: [SnapDirection]
    /// `true` for the Rectangle-extras sections (sixths, ninths, move-to-edge,
    /// vertical thirds, the rarer sizes). The UI collapses them so the
    /// everyday set is what people see; bindings in them still fire.
    let isUnboundByDefault: Bool
}

// MARK: - Conflicts

/// What a key combination collides with.
enum ShortcutConflict: Equatable, Hashable {
    /// Another snap/window action in this same config.
    case snapAction(SnapDirection)
    /// A HopTab shortcut owned elsewhere (app switcher, a profile hotkey).
    /// The associated value is a display name supplied by the caller.
    case otherShortcut(String)
    /// A well-known macOS system shortcut. The associated value is its name.
    case systemShortcut(String)

    /// Phrase suitable for "… conflicts with \(message)".
    var message: String {
        switch self {
        case .snapAction(let direction): return "the \(direction.displayName) shortcut"
        case .otherShortcut(let name):   return name
        case .systemShortcut(let name):  return "\(name) (a macOS system shortcut)"
        }
    }
}

/// A HopTab shortcut that lives outside `SnapShortcutConfig` — the app switcher
/// binding, a per-profile hotkey — passed in so conflict detection can see it.
struct NamedShortcut: Equatable, Hashable {
    let name: String
    let shortcut: CustomShortcut

    init(name: String, shortcut: CustomShortcut) {
        self.name = name
        self.shortcut = shortcut
    }
}

/// One row of a whole-config conflict scan.
struct SnapShortcutConflict: Equatable, Hashable, Identifiable {
    let direction: SnapDirection
    let conflict: ShortcutConflict

    var id: String { "\(direction.rawValue)|\(conflict)" }
    var message: String { "\(direction.displayName) conflicts with \(conflict.message)" }
}

// MARK: - Import / Export

enum ShortcutImportError: LocalizedError, Equatable {
    case notJSON
    case wrongFormat(String)
    case missingVersion
    case unsupportedVersion(Int)
    case noValidBindings
    case invalidBinding(action: String)

    var errorDescription: String? {
        switch self {
        case .notJSON:
            return "That file isn't valid HopTab shortcut JSON."
        case .wrongFormat(let found):
            return "Unrecognised file format \"\(found)\"."
        case .missingVersion:
            return "The file is missing a format version."
        case .unsupportedVersion(let v):
            return "Format version \(v) is newer than this version of HopTab understands."
        case .noValidBindings:
            return "The file contains no shortcuts HopTab can use."
        case .invalidBinding(let action):
            return "The shortcut for \"\(action)\" isn't a usable key combination."
        }
    }
}

// MARK: - Config

struct SnapShortcutConfig: Codable, Equatable {
    var bindings: [SnapDirection: CustomShortcut]

    init(bindings: [SnapDirection: CustomShortcut]) {
        self.bindings = bindings
    }

    /// Rectangle-compatible defaults.
    ///
    /// Combinations already taken by the original set, before the Rectangle-parity
    /// actions were added:
    ///
    ///   ⌃⌥        ← → ↑ ↓ · U I J K · D F G E T · Return C Z · . , · = -
    ///   ⌃⌥⌘       ← →                      (previous / next monitor)
    ///   ⌃⌥⇧       Z                        (redo)
    ///
    /// New defaults are assigned only into gaps in that table that are also free
    /// of macOS system shortcuts (see `KeyCodeMapping.systemShortcuts`):
    ///
    ///   ⌃⌥A       Almost Maximize     (Rectangle's convention)
    ///   ⌃⌥⇧↑      Maximize Height     (Rectangle's convention)
    ///   ⌃⌥⌘↑      Move to Top Edge
    ///   ⌃⌥⌘↓      Move to Bottom Edge
    ///
    /// Rectangle puts move-to-edge on ⌃⌥⌘ + all four arrows, but ⌃⌥⌘← and ⌃⌥⌘→
    /// are already Previous/Next Monitor here, so the horizontal edge moves ship
    /// **unbound** rather than stealing an existing default.
    ///
    /// The sixths, the ninths, the vertical thirds (they are reachable by
    /// pressing Top/Bottom Half twice — the size cycle), Center Half and
    /// Center (Keep Size) also ship unbound: there are too many to bind sanely,
    /// and every one of them is recordable in Settings.
    static let defaults: SnapShortcutConfig = {
        let ctrlOpt = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        let ctrlOptCmd = ctrlOpt | CGEventFlags.maskCommand.rawValue
        let ctrlOptShift = ctrlOpt | CGEventFlags.maskShift.rawValue

        func shortcut(_ mods: UInt64, _ key: Int) -> CustomShortcut {
            CustomShortcut(modifierFlagsRawValue: mods, keyCode: Int64(key))
        }

        return SnapShortcutConfig(bindings: [
            // Halves
            .left:           shortcut(ctrlOpt, kVK_LeftArrow),
            .right:          shortcut(ctrlOpt, kVK_RightArrow),
            .topHalf:        shortcut(ctrlOpt, kVK_UpArrow),
            .bottomHalf:     shortcut(ctrlOpt, kVK_DownArrow),
            // Quarters
            .topLeft:        shortcut(ctrlOpt, kVK_ANSI_U),
            .topRight:       shortcut(ctrlOpt, kVK_ANSI_I),
            .bottomLeft:     shortcut(ctrlOpt, kVK_ANSI_J),
            .bottomRight:    shortcut(ctrlOpt, kVK_ANSI_K),
            // Thirds
            .firstThird:     shortcut(ctrlOpt, kVK_ANSI_D),
            .centerThird:    shortcut(ctrlOpt, kVK_ANSI_F),
            .lastThird:      shortcut(ctrlOpt, kVK_ANSI_G),
            .firstTwoThirds: shortcut(ctrlOpt, kVK_ANSI_E),
            .lastTwoThirds:  shortcut(ctrlOpt, kVK_ANSI_T),
            // Full / center
            .full:           shortcut(ctrlOpt, kVK_Return),
            .center:         shortcut(ctrlOpt, kVK_ANSI_C),
            // Sizing (Rectangle parity)
            .almostMaximize: shortcut(ctrlOpt, kVK_ANSI_A),
            .maximizeHeight: shortcut(ctrlOptShift, kVK_UpArrow),
            // Move to edge — only the vertical pair; ⌃⌥⌘←/→ are the monitor moves
            .moveTopEdge:    shortcut(ctrlOptCmd, kVK_UpArrow),
            .moveBottomEdge: shortcut(ctrlOptCmd, kVK_DownArrow),
            // Monitor movement
            .nextMonitor:     shortcut(ctrlOptCmd, kVK_RightArrow),
            .previousMonitor: shortcut(ctrlOptCmd, kVK_LeftArrow),
            // Undo / Redo
            .undo:           shortcut(ctrlOpt, kVK_ANSI_Z),
            .redo:           shortcut(ctrlOptShift, kVK_ANSI_Z),
            // Universal cycle
            .cycleNext:      shortcut(ctrlOpt, kVK_ANSI_Period),
            .cyclePrevious:  shortcut(ctrlOpt, kVK_ANSI_Comma),
            // Adjacent-window split resize (Rectangle's Larger/Smaller keys)
            .growSplit:      shortcut(ctrlOpt, kVK_ANSI_Equal),
            .shrinkSplit:    shortcut(ctrlOpt, kVK_ANSI_Minus),
        ])
    }()

    // MARK: - Display Grouping

    /// Curated sections for the settings UI, in display order.
    ///
    /// Shape: `[SnapActionGroup]`, each `(id: String, title: String,
    /// directions: [SnapDirection], isUnboundByDefault: Bool)`.
    ///
    /// Guaranteed to cover every `SnapDirection` case exactly once — anything
    /// not curated below lands in a trailing "Other" group.
    static let actionGroups: [SnapActionGroup] = {
        var groups: [SnapActionGroup] = [
            // ---- Everyday (expanded) ----
            SnapActionGroup(
                id: "halves", title: "Halves",
                directions: [.left, .right, .topHalf, .bottomHalf],
                isUnboundByDefault: false
            ),
            SnapActionGroup(
                id: "quarters", title: "Quarters",
                directions: [.topLeft, .topRight, .bottomLeft, .bottomRight],
                isUnboundByDefault: false
            ),
            SnapActionGroup(
                id: "thirds", title: "Thirds",
                directions: [
                    .firstThird, .centerThird, .lastThird,
                    .firstTwoThirds, .lastTwoThirds,
                ],
                isUnboundByDefault: false
            ),
            SnapActionGroup(
                id: "sizing", title: "Sizing",
                directions: [.full, .center, .growSplit, .shrinkSplit],
                isUnboundByDefault: false
            ),
            SnapActionGroup(
                id: "displays", title: "Displays",
                directions: [.previousMonitor, .nextMonitor],
                isUnboundByDefault: false
            ),
            SnapActionGroup(
                id: "cycle", title: "Cycle",
                directions: [.cycleNext, .cyclePrevious],
                isUnboundByDefault: false
            ),
            SnapActionGroup(
                id: "history", title: "History",
                directions: [.undo, .redo],
                isUnboundByDefault: false
            ),

            // ---- Rectangle extras (collapsed; bindings still honoured) ----
            SnapActionGroup(
                id: "vertical-thirds", title: "Vertical thirds",
                directions: [.topThird, .bottomThird, .topTwoThirds, .bottomTwoThirds],
                isUnboundByDefault: true
            ),
            SnapActionGroup(
                id: "sizing-extras", title: "More sizing",
                directions: [.almostMaximize, .maximizeHeight, .centerHalf, .centerKeepSize],
                isUnboundByDefault: true
            ),
            SnapActionGroup(
                id: "move", title: "Move to edge",
                directions: [.moveLeftEdge, .moveRightEdge, .moveTopEdge, .moveBottomEdge],
                isUnboundByDefault: true
            ),
            SnapActionGroup(
                id: "sixths", title: "Sixths",
                directions: [
                    .topLeftSixth, .topCenterSixth, .topRightSixth,
                    .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
                ],
                isUnboundByDefault: true
            ),
            SnapActionGroup(
                id: "ninths", title: "Ninths",
                directions: [
                    .topLeftNinth, .topCenterNinth, .topRightNinth,
                    .middleLeftNinth, .middleCenterNinth, .middleRightNinth,
                    .bottomLeftNinth, .bottomCenterNinth, .bottomRightNinth,
                ],
                isUnboundByDefault: true
            ),
        ]

        // Safety net: any SnapDirection added to the enum later shows up in the
        // UI automatically instead of silently disappearing.
        let curated = Set(groups.flatMap(\.directions))
        let remaining = SnapDirection.allCases.filter { !curated.contains($0) }
        if !remaining.isEmpty {
            groups.append(
                SnapActionGroup(
                    id: "other", title: "Other",
                    directions: remaining, isUnboundByDefault: true
                )
            )
        }
        return groups
    }()

    /// The group a direction belongs to, or `nil` if it somehow isn't curated.
    static func group(for direction: SnapDirection) -> SnapActionGroup? {
        actionGroups.first { $0.directions.contains(direction) }
    }

    // MARK: - Conflict Detection

    /// What `direction`'s current binding collides with, or `nil`.
    ///
    /// Pass shortcuts owned elsewhere (the app switcher, profile hotkeys) in
    /// `externals` so they participate in the scan.
    ///
    /// Comparison uses `CustomShortcut.matchKey` — the ⌃⌥⇧⌘ + key-code tuple
    /// `HotkeyService` actually matches on — so two bindings that differ only in
    /// opt-in fn / left-right data are still reported as colliding. They really
    /// do collide today.
    func conflict(
        for direction: SnapDirection,
        against externals: [NamedShortcut] = []
    ) -> ShortcutConflict? {
        guard let shortcut = bindings[direction] else { return nil }
        return conflict(for: shortcut, excluding: direction, against: externals)
    }

    /// What `shortcut` would collide with if it were assigned. Use this to warn
    /// *before* committing a freshly recorded combination.
    func conflict(
        for shortcut: CustomShortcut,
        excluding direction: SnapDirection? = nil,
        against externals: [NamedShortcut] = []
    ) -> ShortcutConflict? {
        let key = shortcut.matchKey

        // Deterministic order — allCases, not dictionary order.
        for other in SnapDirection.allCases where other != direction {
            if let bound = bindings[other], bound.matchKey == key {
                return .snapAction(other)
            }
        }
        for external in externals where external.shortcut.matchKey == key {
            return .otherShortcut(external.name)
        }
        if let name = KeyCodeMapping.systemShortcutName(
            modifiers: shortcut.modifierFlags,
            keyCode: Int(shortcut.keyCode),
            function: shortcut.requiresFunctionModifier
        ) {
            return .systemShortcut(name)
        }
        return nil
    }

    /// Every conflicting binding in this config, in `SnapDirection.allCases`
    /// order. A colliding pair is reported twice, once from each side.
    func conflicts(against externals: [NamedShortcut] = []) -> [SnapShortcutConflict] {
        SnapDirection.allCases.compactMap { direction in
            conflict(for: direction, against: externals)
                .map { SnapShortcutConflict(direction: direction, conflict: $0) }
        }
    }

    /// Convenience: is this exact combination already spoken for?
    func isTaken(
        _ shortcut: CustomShortcut,
        excluding direction: SnapDirection? = nil,
        against externals: [NamedShortcut] = []
    ) -> Bool {
        conflict(for: shortcut, excluding: direction, against: externals) != nil
    }

    // MARK: - Upgrade Helpers

    /// Returns a copy with defaults filled in **only** for actions that have no
    /// binding at all. Never touches, rebinds or drops anything the user set.
    ///
    /// Deliberately NOT applied automatically on load: a stored config cannot
    /// distinguish "this action didn't exist yet" from "the user cleared it", so
    /// auto-filling would resurrect shortcuts people deliberately removed. Wire
    /// it to an explicit "Add new default shortcuts" button instead.
    func applyingMissingDefaults() -> SnapShortcutConfig {
        var merged = bindings
        for (direction, shortcut) in SnapShortcutConfig.defaults.bindings where merged[direction] == nil {
            // Skip a default that would collide with something the user set.
            let candidate = SnapShortcutConfig(bindings: merged)
            guard candidate.conflict(for: shortcut, excluding: direction) == nil else { continue }
            merged[direction] = shortcut
        }
        return SnapShortcutConfig(bindings: merged)
    }

    /// Directions with no binding — the set a "discoverability" UI can offer.
    var unboundDirections: [SnapDirection] {
        SnapDirection.allCases.filter { bindings[$0] == nil }
    }

    // MARK: - Codable
    //
    // Hand-written to preserve the EXACT legacy wire format and to be lenient
    // about unknown content. Swift's synthesised `Dictionary` coding for a
    // non-String/Int key emits a flat unkeyed array of alternating key/value:
    //
    //     {"bindings":["left",{"modifierFlagsRawValue":786432,"keyCode":123}, …]}
    //
    // That is what is already sitting in `UserDefaults` for every existing user,
    // so the encoder below reproduces it byte-for-byte.
    //
    // Leniency matters: the synthesised decoder throws on an unrecognised
    // SnapDirection raw value, and `current` falls back to `.defaults` when
    // decoding throws — so one unknown action from a newer build (or a
    // hand-edited file) used to wipe every shortcut the user had. Unknown
    // actions and unreadable values are now skipped instead.

    private enum CodingKeys: String, CodingKey {
        case bindings
    }

    /// Decodes a `CustomShortcut` without ever throwing, so one bad element in
    /// the unkeyed container can be skipped rather than failing the whole
    /// config. (Throwing here would not advance the container's index.)
    private struct LenientShortcut: Decodable {
        let value: CustomShortcut?
        init(from decoder: Decoder) throws {
            value = try? CustomShortcut(from: decoder)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Legacy / current format: flat [key, value, key, value, …] array.
        if var list = try? container.nestedUnkeyedContainer(forKey: .bindings) {
            var result: [SnapDirection: CustomShortcut] = [:]
            while !list.isAtEnd {
                guard let raw = try? list.decode(String.self) else { break }
                guard let boxed = try? list.decode(LenientShortcut.self) else { break }
                if let direction = SnapDirection(rawValue: raw), let shortcut = boxed.value {
                    result[direction] = shortcut
                }
            }
            bindings = result
            return
        }

        // Tolerated alternative: a plain JSON object keyed by action name.
        // Nothing HopTab writes uses this, but hand-edited and exported files do.
        let keyed = try container.decode([String: LenientShortcut].self, forKey: .bindings)
        var result: [SnapDirection: CustomShortcut] = [:]
        for (raw, boxed) in keyed {
            if let direction = SnapDirection(rawValue: raw), let shortcut = boxed.value {
                result[direction] = shortcut
            }
        }
        bindings = result
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        var list = container.nestedUnkeyedContainer(forKey: .bindings)
        // allCases order, not dictionary order, so the payload is stable and
        // repeated saves don't churn UserDefaults.
        for direction in SnapDirection.allCases {
            guard let shortcut = bindings[direction] else { continue }
            try list.encode(direction.rawValue)
            try list.encode(shortcut)
        }
    }

    // MARK: - Import / Export

    /// Bumped when the exported shape changes incompatibly.
    static let exportFormatVersion = 1
    static let exportFormatIdentifier = "hoptab.snapShortcuts"

    private struct ExportPayload: Codable {
        let format: String
        let version: Int
        let exportedAt: String?
        let bindings: [String: CustomShortcut]
    }

    /// The whole configuration as pretty-printed, human-editable JSON.
    ///
    ///     {
    ///       "format": "hoptab.snapShortcuts",
    ///       "version": 1,
    ///       "exportedAt": "2026-09-13T10:00:00Z",
    ///       "bindings": { "left": { "modifierFlagsRawValue": 786432, "keyCode": 123 }, … }
    ///     }
    ///
    /// Note this is intentionally *not* the `UserDefaults` wire format: export
    /// is keyed by action name so a human can read and edit it.
    func exportJSON() throws -> Data {
        var named: [String: CustomShortcut] = [:]
        for (direction, shortcut) in bindings {
            named[direction.rawValue] = shortcut
        }
        let formatter = ISO8601DateFormatter()
        let payload = ExportPayload(
            format: SnapShortcutConfig.exportFormatIdentifier,
            version: SnapShortcutConfig.exportFormatVersion,
            exportedAt: formatter.string(from: Date()),
            bindings: named
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(payload)
    }

    /// Parse and fully validate an exported payload.
    ///
    /// Throws `ShortcutImportError` on anything unrecognised and never touches
    /// persisted state, so a bad file cannot corrupt the stored config. Unknown
    /// action names are skipped (forward compatibility with a newer HopTab);
    /// a *known* action with an unusable combination is rejected outright
    /// rather than silently dropped.
    static func importJSON(_ data: Data) throws -> SnapShortcutConfig {
        guard !data.isEmpty else { throw ShortcutImportError.notJSON }

        let payload: ExportPayload
        do {
            payload = try JSONDecoder().decode(ExportPayload.self, from: data)
        } catch {
            // Distinguish "valid JSON, wrong shape" from "not JSON at all" so
            // the UI can say something useful.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let format = object["format"] as? String,
                   format != exportFormatIdentifier {
                    throw ShortcutImportError.wrongFormat(format)
                }
                if object["version"] == nil { throw ShortcutImportError.missingVersion }
                throw ShortcutImportError.noValidBindings
            }
            throw ShortcutImportError.notJSON
        }

        guard payload.format == exportFormatIdentifier else {
            throw ShortcutImportError.wrongFormat(payload.format)
        }
        guard payload.version > 0 else { throw ShortcutImportError.missingVersion }
        guard payload.version <= exportFormatVersion else {
            throw ShortcutImportError.unsupportedVersion(payload.version)
        }

        var result: [SnapDirection: CustomShortcut] = [:]
        for (raw, shortcut) in payload.bindings {
            guard let direction = SnapDirection(rawValue: raw) else {
                continue   // action from a newer build — ignore, don't fail
            }
            guard shortcut.isUsable else {
                throw ShortcutImportError.invalidBinding(action: raw)
            }
            result[direction] = shortcut
        }
        guard !result.isEmpty else { throw ShortcutImportError.noValidBindings }
        return SnapShortcutConfig(bindings: result)
    }

    /// Validate, then replace this config wholesale. Atomic: on any error
    /// `self` is left exactly as it was.
    mutating func importJSON(_ data: Data) throws {
        self = try SnapShortcutConfig.importJSON(data)
    }

    // MARK: - Persistence

    private static let storageKey = "snapShortcuts"

    static var current: SnapShortcutConfig {
        get {
            #if DEBUG
            runCodableSelfCheckOnce()
            #endif
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let config = try? JSONDecoder().decode(SnapShortcutConfig.self, from: data)
            else { return .defaults }
            return config
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: storageKey)
            }
        }
    }
}

// MARK: - Codable Compatibility Self-check

extension SnapShortcutConfig {
    /// A payload captured from a real pre-upgrade install (`defaults read
    /// com.hoptab.app snapShortcuts`). Trimmed to the distinctive cases:
    /// a plain ⌃⌥ binding, a ⌃⌥⌘ binding, and an unknown action name that a
    /// newer build might have written.
    static let legacySamplePayload = """
    {"bindings":["left",{"modifierFlagsRawValue":786432,"keyCode":123},\
    "nextMonitor",{"modifierFlagsRawValue":1835008,"keyCode":124},\
    "undo",{"modifierFlagsRawValue":786432,"keyCode":6},\
    "someFutureAction",{"modifierFlagsRawValue":786432,"keyCode":49}]}
    """

    /// Proves the backwards-compatibility claim at runtime. Returns the list of
    /// failures; empty means the old stored format still round-trips.
    static func codableCompatibilityFailures() -> [String] {
        var failures: [String] = []

        guard let data = legacySamplePayload.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(SnapShortcutConfig.self, from: data)
        else {
            return ["legacy payload failed to decode at all"]
        }

        // 1. Known actions survive, with identical flags and key codes.
        if decoded.bindings[.left]?.modifierFlagsRawValue != 786432
            || decoded.bindings[.left]?.keyCode != 123 {
            failures.append("legacy .left binding did not decode unchanged")
        }
        if decoded.bindings[.nextMonitor]?.modifierFlagsRawValue != 1835008 {
            failures.append("legacy .nextMonitor binding did not decode unchanged")
        }
        if decoded.bindings[.undo]?.keyCode != 6 {
            failures.append("legacy .undo binding did not decode unchanged")
        }
        // 2. An unknown action is skipped, not fatal.
        if decoded.bindings.count != 3 {
            failures.append("unknown action was not skipped (got \(decoded.bindings.count) bindings)")
        }
        // 3. Legacy shortcuts stay side- and fn-agnostic.
        if decoded.bindings[.left]?.requiresFunctionModifier != false
            || decoded.bindings[.left]?.isSideSpecific != false {
            failures.append("legacy binding gained fn / side data")
        }
        // 4. Re-encoding a legacy-only shortcut produces the legacy two-key shape.
        if let left = decoded.bindings[.left],
           let reencoded = try? JSONEncoder().encode(left),
           let text = String(data: reencoded, encoding: .utf8) {
            if text.contains("usesFunctionModifier") || text.contains("deviceModifierFlags") {
                failures.append("legacy shortcut re-encoded with extra keys: \(text)")
            }
        } else {
            failures.append("legacy shortcut failed to re-encode")
        }
        // 5. Full round-trip through the config encoder is stable.
        if let reencoded = try? JSONEncoder().encode(decoded),
           let again = try? JSONDecoder().decode(SnapShortcutConfig.self, from: reencoded) {
            if again.bindings != decoded.bindings {
                failures.append("config round-trip changed the bindings")
            }
        } else {
            failures.append("config failed to round-trip")
        }
        // 6. Undo and Redo must remain distinguishable (the Shift-strip bug).
        let undo = SnapShortcutConfig.defaults.bindings[.undo]
        let redo = SnapShortcutConfig.defaults.bindings[.redo]
        if undo?.matchKey == redo?.matchKey {
            failures.append("Undo and Redo defaults collide")
        }
        // 7. No two default bindings may share a combination.
        if let first = SnapShortcutConfig.defaults.conflicts().first {
            failures.append("default bindings conflict: \(first.message)")
        }

        return failures
    }

    #if DEBUG
    private static let selfCheckToken: Void = {
        let failures = codableCompatibilityFailures()
        assert(failures.isEmpty, "SnapShortcutConfig compatibility check failed: \(failures)")
        return ()
    }()

    /// Runs the compatibility assertions once, the first time the config is read.
    static func runCodableSelfCheckOnce() {
        _ = selfCheckToken
    }
    #endif
}
