import Carbon.HIToolbox
import CoreGraphics
import Foundation


enum ShortcutPreset: String, Codable, CaseIterable, Identifiable {
    case optionTab
    case controlTab
    case optionBacktick
    case commandTab

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .optionTab: return "\u{2325} Option + Tab"
        case .controlTab: return "\u{2303} Control + Tab"
        case .optionBacktick: return "\u{2325} Option + `"
        case .commandTab: return "\u{2318} Command + Tab (replaces macOS)"
        }
    }

    var modifierFlag: CGEventFlags {
        switch self {
        case .optionTab, .optionBacktick: return .maskAlternate
        case .controlTab: return .maskControl
        case .commandTab: return .maskCommand
        }
    }

    var keyCode: Int64 {
        switch self {
        case .optionTab, .controlTab, .commandTab: return Int64(kVK_Tab)
        case .optionBacktick: return Int64(kVK_ANSI_Grave)
        }
    }

    var keyName: String {
        switch self {
        case .optionTab, .controlTab, .commandTab: return "Tab"
        case .optionBacktick: return "`"
        }
    }

    var modifierName: String {
        switch self {
        case .optionTab, .optionBacktick: return "Option"
        case .controlTab: return "Control"
        case .commandTab: return "Command"
        }
    }

    // MARK: - Persistence

    private static let storageKey = "shortcutPreset"

    static var current: ShortcutPreset {
        get {
            guard let raw = UserDefaults.standard.string(forKey: storageKey),
                  let preset = ShortcutPreset(rawValue: raw)
            else { return .optionTab }
            return preset
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: storageKey)
        }
    }
}


/// A user-recorded key combination.
///
/// ## Wire-format compatibility
///
/// The two stored properties `modifierFlagsRawValue` and `keyCode` are the
/// ORIGINAL shape and must never change: they are persisted in `UserDefaults`
/// under `snapShortcuts`, `customAppShortcut`, `customProfileShortcut` and
/// inside every `Profile`. Everything added since is **optional extra data**,
/// encoded with `encodeIfPresent` — a shortcut that uses none of it still
/// serialises to exactly `{"modifierFlagsRawValue":N,"keyCode":N}`, so an older
/// build reads it back unchanged, and an older payload decodes here with the
/// extras `nil`.
///
/// `modifierFlags` deliberately still reports ONLY the four device-independent
/// masks (⌃⌥⇧⌘). `HotkeyService` matches on that value, so adding `fn` or the
/// device-dependent side bits to it would silently change matching for every
/// existing binding. The extras are surfaced separately through
/// `requiresFunctionModifier`, `deviceModifierFlags` and `matchingFlags`.
struct CustomShortcut: Codable, Equatable, Hashable {
    let modifierFlagsRawValue: UInt64
    let keyCode: Int64

    /// Opt-in: the fn (Globe) key is part of this combination.
    /// `nil` — the legacy value — means "not recorded", i.e. fn-agnostic.
    let usesFunctionModifier: Bool?

    /// Opt-in: raw `NX_DEVICE*` bits captured from the event, recording which
    /// physical side each modifier was pressed on. `nil` (legacy) means the
    /// shortcut is side-agnostic, which is also how matching behaves today.
    let deviceModifierFlagsRawValue: UInt64?

    init(
        modifierFlagsRawValue: UInt64,
        keyCode: Int64,
        usesFunctionModifier: Bool? = nil,
        deviceModifierFlagsRawValue: UInt64? = nil
    ) {
        self.modifierFlagsRawValue = modifierFlagsRawValue
        self.keyCode = keyCode
        // Normalise "no extra data" to nil so the encoded payload stays
        // byte-identical to the legacy format for ordinary shortcuts.
        self.usesFunctionModifier = (usesFunctionModifier == true) ? true : nil
        let device = (deviceModifierFlagsRawValue ?? 0) & KeyCodeMapping.deviceModifierMask
        self.deviceModifierFlagsRawValue = device == 0 ? nil : device
    }

    // MARK: Codable (hand-written: additive, `encodeIfPresent` only)

    private enum CodingKeys: String, CodingKey {
        case modifierFlagsRawValue
        case keyCode
        case usesFunctionModifier
        case deviceModifierFlagsRawValue
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let mods = try c.decode(UInt64.self, forKey: .modifierFlagsRawValue)
        let key = try c.decode(Int64.self, forKey: .keyCode)
        let fn = try c.decodeIfPresent(Bool.self, forKey: .usesFunctionModifier)
        let device = try c.decodeIfPresent(UInt64.self, forKey: .deviceModifierFlagsRawValue)
        self.init(
            modifierFlagsRawValue: mods,
            keyCode: key,
            usesFunctionModifier: fn,
            deviceModifierFlagsRawValue: device
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(modifierFlagsRawValue, forKey: .modifierFlagsRawValue)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encodeIfPresent(usesFunctionModifier, forKey: .usesFunctionModifier)
        try c.encodeIfPresent(deviceModifierFlagsRawValue, forKey: .deviceModifierFlagsRawValue)
    }

    // MARK: Derived values

    /// The four device-independent masks only — what `HotkeyService` matches on.
    /// Unchanged by the fn / left-right additions, on purpose.
    var modifierFlags: CGEventFlags {
        CGEventFlags(rawValue: modifierFlagsRawValue)
    }

    /// Whether fn was recorded as an intentional part of this combination.
    var requiresFunctionModifier: Bool { usesFunctionModifier == true }

    /// Raw `NX_DEVICE*` bits, or 0 when the shortcut is side-agnostic.
    var deviceModifierFlags: UInt64 { deviceModifierFlagsRawValue ?? 0 }

    /// `true` when either Control, Option, Shift or Command was pinned to a
    /// specific physical key.
    var isSideSpecific: Bool { deviceModifierFlags != 0 }

    /// Which side the given base modifier must be pressed on.
    func side(for base: CGEventFlags) -> ModifierSide {
        KeyCodeMapping.side(of: base, in: deviceModifierFlags)
    }

    /// Flags including `fn`, for a future `HotkeyService` that matches fn.
    /// NOT used by the current matcher — see the type doc.
    var matchingFlags: CGEventFlags {
        var flags = modifierFlags
        if requiresFunctionModifier { flags.insert(.maskSecondaryFn) }
        return flags
    }

    /// The same combination with Shift removed.
    ///
    /// Switcher-style bindings (app switcher, profile switcher, per-profile
    /// hotkeys) must not carry Shift: `HotkeyService` treats Shift as "cycle
    /// backward" for them, so a Shift in the base binding stops the switcher
    /// from ever activating. Apply this before persisting one of those.
    var withoutShift: CustomShortcut {
        var flags = modifierFlags
        guard flags.contains(.maskShift) else { return self }
        flags.remove(.maskShift)
        var device = deviceModifierFlags
        device &= ~(KeyCodeMapping.deviceLeftShift | KeyCodeMapping.deviceRightShift)
        return CustomShortcut(
            modifierFlagsRawValue: flags.rawValue,
            keyCode: keyCode,
            usesFunctionModifier: usesFunctionModifier,
            deviceModifierFlagsRawValue: device
        )
    }

    /// Same combination ignoring the opt-in extras — the granularity at which
    /// `HotkeyService` actually matches today, and therefore the granularity at
    /// which two bindings genuinely collide.
    var matchKey: MatchKey {
        MatchKey(
            modifiers: modifierFlagsRawValue & KeyCodeMapping.matchedModifierMask.rawValue,
            keyCode: keyCode
        )
    }

    /// Identity of a combination for conflict detection.
    struct MatchKey: Hashable {
        let modifiers: UInt64
        let keyCode: Int64
    }

    var keyName: String {
        KeyCodeMapping.displayName(for: Int(keyCode)) ?? "Key \(keyCode)"
    }

    var modifierName: String {
        let names = KeyCodeMapping.modifierDisplayNames(
            for: modifierFlags,
            function: requiresFunctionModifier,
            deviceFlags: deviceModifierFlags
        )
        return names.isEmpty ? "" : names.joined(separator: " + ")
    }

    var displayName: String {
        let mods = KeyCodeMapping.modifierSymbols(
            for: modifierFlags,
            function: requiresFunctionModifier,
            deviceFlags: deviceModifierFlags
        )
        return "\(mods)\(keyName)"
    }

    // MARK: Validation

    /// Whether this combination is something HopTab can actually register:
    /// a real trigger key plus at least one of Control / Option / Command.
    /// Shift alone is not enough — it is the reverse-cycle modifier.
    var isUsable: Bool {
        let key = Int(keyCode)
        guard key >= 0, key <= 0xFF else { return false }
        guard !KeyCodeMapping.forbiddenKeyCodes.contains(key) else { return false }
        guard !KeyCodeMapping.modifierKeyCodes.contains(key) else { return false }
        let mods = modifierFlags
        return mods.contains(.maskControl)
            || mods.contains(.maskAlternate)
            || mods.contains(.maskCommand)
    }
}


enum ShortcutSelection: Equatable {
    case preset(ShortcutPreset)
    case custom(CustomShortcut)

    var modifierFlags: CGEventFlags {
        switch self {
        case .preset(let p): return p.modifierFlag
        case .custom(let c): return c.modifierFlags
        }
    }

    var keyCode: Int64 {
        switch self {
        case .preset(let p): return p.keyCode
        case .custom(let c): return c.keyCode
        }
    }

    var displayName: String {
        switch self {
        case .preset(let p): return p.displayName
        case .custom(let c): return c.displayName
        }
    }

    var modifierName: String {
        switch self {
        case .preset(let p): return p.modifierName
        case .custom(let c): return c.modifierName
        }
    }

    var keyName: String {
        switch self {
        case .preset(let p): return p.keyName
        case .custom(let c): return c.keyName
        }
    }

    // MARK: - Persistence

    private static let modeKey = "shortcutMode"
    private static let customDataKey = "customAppShortcut"

    static var current: ShortcutSelection {
        get {
            let mode = UserDefaults.standard.string(forKey: modeKey) ?? "preset"
            if mode == "custom",
               let data = UserDefaults.standard.data(forKey: customDataKey),
               let custom = try? JSONDecoder().decode(CustomShortcut.self, from: data) {
                return .custom(custom)
            }
            return .preset(ShortcutPreset.current)
        }
        set {
            switch newValue {
            case .preset(let p):
                UserDefaults.standard.set("preset", forKey: modeKey)
                ShortcutPreset.current = p
            case .custom(let c):
                UserDefaults.standard.set("custom", forKey: modeKey)
                if let data = try? JSONEncoder().encode(c) {
                    UserDefaults.standard.set(data, forKey: customDataKey)
                }
            }
        }
    }


    private static let profileModeKey = "profileShortcutMode"
    private static let profileDataKey = "customProfileShortcut"

    static var isCustomProfileShortcut: Bool {
        get { UserDefaults.standard.string(forKey: profileModeKey) == "custom" }
        set { UserDefaults.standard.set(newValue ? "custom" : "auto", forKey: profileModeKey) }
    }

    static var savedProfileShortcut: CustomShortcut? {
        get {
            guard let data = UserDefaults.standard.data(forKey: profileDataKey) else { return nil }
            return try? JSONDecoder().decode(CustomShortcut.self, from: data)
        }
        set {
            if let c = newValue, let data = try? JSONEncoder().encode(c) {
                UserDefaults.standard.set(data, forKey: profileDataKey)
            } else {
                UserDefaults.standard.removeObject(forKey: profileDataKey)
            }
        }
    }
}
