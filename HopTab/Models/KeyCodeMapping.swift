import Carbon.HIToolbox
import CoreGraphics

/// Which physical side of the keyboard a modifier must be pressed on.
///
/// `either` is the historical (and default) behaviour: HopTab matches on the
/// device-**independent** modifier masks, so left Control and right Control are
/// the same key. `left` / `right` are opt-in extra data recorded alongside a
/// shortcut; see `CustomShortcut.deviceModifierFlagsRawValue`.
enum ModifierSide: String, Codable, Equatable, Hashable {
    case either
    case left
    case right

    /// Short marker for compact display, e.g. `⌃ᴸ`. Empty for `.either`.
    var symbol: String {
        switch self {
        case .either: return ""
        case .left:   return "\u{1D38}"   // ᴸ
        case .right:  return "\u{1D3F}"   // ᴿ
        }
    }

    var longName: String {
        switch self {
        case .either: return ""
        case .left:   return "left"
        case .right:  return "right"
        }
    }
}

enum KeyCodeMapping {
    // MARK: - Key Code to Display Name

    static func displayName(for keyCode: Int) -> String? {
        return keyNames[keyCode]
    }

    // MARK: - Modifier Display Names

    static func modifierDisplayNames(for flags: CGEventFlags) -> [String] {
        modifierDisplayNames(for: flags, function: false, deviceFlags: 0)
    }

    /// Long-form modifier names, optionally including the `fn` modifier and
    /// left/right side annotations captured from the raw event.
    static func modifierDisplayNames(
        for flags: CGEventFlags,
        function: Bool,
        deviceFlags: UInt64
    ) -> [String] {
        var names: [String] = []
        if function { names.append("fn") }
        func annotate(_ base: String, _ side: ModifierSide) -> String {
            side == .either ? base : "\(base) (\(side.longName))"
        }
        if flags.contains(.maskControl) {
            names.append(annotate("\u{2303}Control", side(of: .maskControl, in: deviceFlags)))
        }
        if flags.contains(.maskAlternate) {
            names.append(annotate("\u{2325}Option", side(of: .maskAlternate, in: deviceFlags)))
        }
        if flags.contains(.maskShift) {
            names.append(annotate("\u{21E7}Shift", side(of: .maskShift, in: deviceFlags)))
        }
        if flags.contains(.maskCommand) {
            names.append(annotate("\u{2318}Command", side(of: .maskCommand, in: deviceFlags)))
        }
        return names
    }

    static func modifierSymbols(for flags: CGEventFlags) -> String {
        modifierSymbols(for: flags, function: false, deviceFlags: 0)
    }

    /// Compact modifier glyphs in Apple's canonical order (fn ⌃ ⌥ ⇧ ⌘), with an
    /// `ᴸ`/`ᴿ` marker appended to any modifier that was recorded side-specific.
    static func modifierSymbols(
        for flags: CGEventFlags,
        function: Bool,
        deviceFlags: UInt64
    ) -> String {
        var s = ""
        if function { s += "fn" }
        if flags.contains(.maskControl)   { s += "\u{2303}" + side(of: .maskControl, in: deviceFlags).symbol }
        if flags.contains(.maskAlternate) { s += "\u{2325}" + side(of: .maskAlternate, in: deviceFlags).symbol }
        if flags.contains(.maskShift)     { s += "\u{21E7}" + side(of: .maskShift, in: deviceFlags).symbol }
        if flags.contains(.maskCommand)   { s += "\u{2318}" + side(of: .maskCommand, in: deviceFlags).symbol }
        return s
    }

    // MARK: - Modifier Key Codes (rejected as trigger keys)

    static let modifierKeyCodes: Set<Int> = [
        kVK_Shift, kVK_RightShift,
        kVK_Control, kVK_RightControl,
        kVK_Option, kVK_RightOption,
        kVK_Command, kVK_RightCommand,
        kVK_Function,
        kVK_CapsLock,
    ]

    // MARK: - Forbidden Key Codes

    static let forbiddenKeyCodes: Set<Int> = [
        kVK_Escape,
        kVK_CapsLock,
    ]

    // MARK: - Function (fn) Modifier

    /// Keys that make macOS set the `fn` / `NSEvent.ModifierFlags.function` bit
    /// on their own, whether or not the user touched the fn (Globe) key: the
    /// arrows, navigation cluster, forward-delete, help and F1–F20.
    ///
    /// The recorder must NOT treat `fn` as an intentional modifier for these,
    /// otherwise every arrow-key binding would silently become an fn binding.
    static let keysImplyingFunctionModifier: Set<Int> = {
        var keys: Set<Int> = [
            kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
            kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown,
            kVK_ForwardDelete, kVK_Help,
        ]
        keys.formUnion([
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7,
            kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14,
            kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ])
        return keys
    }()

    // MARK: - Device-dependent (left/right) Modifier Masks
    //
    // Values from <IOKit/hidsystem/IOLLEvent.h>. They live in the low 16 bits
    // of an NSEvent's raw `modifierFlags` (the device-INdependent masks that
    // CGEventFlags exposes occupy the high bits), so they can be read off any
    // key or flagsChanged event without importing IOKit.

    static let deviceLeftControl:  UInt64 = 0x0000_0001   // NX_DEVICELCTLKEYMASK
    static let deviceRightControl: UInt64 = 0x0000_2000   // NX_DEVICERCTLKEYMASK
    static let deviceLeftShift:    UInt64 = 0x0000_0002   // NX_DEVICELSHIFTKEYMASK
    static let deviceRightShift:   UInt64 = 0x0000_0004   // NX_DEVICERSHIFTKEYMASK
    static let deviceLeftCommand:  UInt64 = 0x0000_0008   // NX_DEVICELCMDKEYMASK
    static let deviceRightCommand: UInt64 = 0x0000_0010   // NX_DEVICERCMDKEYMASK
    static let deviceLeftOption:   UInt64 = 0x0000_0020   // NX_DEVICELALTKEYMASK
    static let deviceRightOption:  UInt64 = 0x0000_0040   // NX_DEVICERALTKEYMASK

    /// Union of every device-dependent bit we understand. Used to strip noise
    /// (caps-lock state bits, vendor bits) out of a captured raw flags value.
    static let deviceModifierMask: UInt64 =
        deviceLeftControl | deviceRightControl |
        deviceLeftShift   | deviceRightShift   |
        deviceLeftCommand | deviceRightCommand |
        deviceLeftOption  | deviceRightOption

    /// The four device-independent modifier masks HopTab matches on today.
    static let matchedModifierMask: CGEventFlags =
        CGEventFlags([.maskControl, .maskAlternate, .maskShift, .maskCommand])

    /// Resolve which side a given base modifier was pressed on.
    ///
    /// Returns `.either` when no side information was recorded, or when both
    /// sides are set (the user held both Shift keys, say) — matching stays
    /// side-agnostic in that case.
    static func side(of base: CGEventFlags, in deviceFlags: UInt64) -> ModifierSide {
        let pair: (left: UInt64, right: UInt64)
        switch base {
        case .maskControl:   pair = (deviceLeftControl, deviceRightControl)
        case .maskAlternate: pair = (deviceLeftOption, deviceRightOption)
        case .maskShift:     pair = (deviceLeftShift, deviceRightShift)
        case .maskCommand:   pair = (deviceLeftCommand, deviceRightCommand)
        default:             return .either
        }
        let hasLeft = deviceFlags & pair.left != 0
        let hasRight = deviceFlags & pair.right != 0
        if hasLeft && !hasRight { return .left }
        if hasRight && !hasLeft { return .right }
        return .either
    }

    // MARK: - Well-known macOS System Shortcuts
    //
    // Used by `SnapShortcutConfig.conflict(for:)` to warn when a user binds
    // something macOS already owns. Deliberately conservative: only shortcuts
    // that are on by default on a stock system.

    struct SystemShortcut: Equatable, Hashable {
        /// Device-independent modifiers that must be held, exactly.
        let modifiers: CGEventFlags
        /// Whether the fn (Globe) key is part of the combination.
        let requiresFunction: Bool
        let keyCode: Int
        /// User-facing description, e.g. "Mission Control".
        let name: String

        static func == (lhs: SystemShortcut, rhs: SystemShortcut) -> Bool {
            lhs.modifiers.rawValue == rhs.modifiers.rawValue
                && lhs.requiresFunction == rhs.requiresFunction
                && lhs.keyCode == rhs.keyCode
                && lhs.name == rhs.name
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(modifiers.rawValue)
            hasher.combine(requiresFunction)
            hasher.combine(keyCode)
            hasher.combine(name)
        }
    }

    static let systemShortcuts: [SystemShortcut] = {
        let ctrl = CGEventFlags.maskControl
        let cmd = CGEventFlags.maskCommand
        let shift = CGEventFlags.maskShift
        let opt = CGEventFlags.maskAlternate

        func s(_ mods: CGEventFlags, _ key: Int, _ name: String, fn: Bool = false) -> SystemShortcut {
            SystemShortcut(modifiers: mods, requiresFunction: fn, keyCode: key, name: name)
        }

        return [
            // Mission Control / Spaces
            s(ctrl, kVK_UpArrow, "Mission Control"),
            s(ctrl, kVK_DownArrow, "Application Windows"),
            s(ctrl, kVK_LeftArrow, "Move one space left"),
            s(ctrl, kVK_RightArrow, "Move one space right"),

            // Switchers and search
            s(cmd, kVK_Tab, "the macOS app switcher"),
            s([cmd, shift], kVK_Tab, "the macOS app switcher (reverse)"),
            s(cmd, kVK_ANSI_Grave, "Cycle windows in the front app"),
            s(cmd, kVK_Space, "Spotlight"),
            s([cmd, opt], kVK_Space, "Finder search window"),
            s([cmd, ctrl], kVK_Space, "the Emoji & Symbols picker"),

            // Screenshots, full screen, Dock
            s([cmd, shift], kVK_ANSI_3, "Screenshot (whole screen)"),
            s([cmd, shift], kVK_ANSI_4, "Screenshot (selection)"),
            s([cmd, shift], kVK_ANSI_5, "the Screenshot app"),
            s([cmd, ctrl], kVK_ANSI_F, "Full Screen"),
            s([cmd, opt], kVK_ANSI_D, "Show/Hide the Dock"),

            // macOS 15 (Sequoia) native window tiling — fn + Control + arrow.
            s(ctrl, kVK_LeftArrow, "macOS window tiling (Left)", fn: true),
            s(ctrl, kVK_RightArrow, "macOS window tiling (Right)", fn: true),
            s(ctrl, kVK_UpArrow, "macOS window tiling (Top / Fill)", fn: true),
            s(ctrl, kVK_DownArrow, "macOS window tiling (Bottom)", fn: true),
            s([ctrl, shift], kVK_LeftArrow, "macOS window tiling (Left quarters)", fn: true),
            s([ctrl, shift], kVK_RightArrow, "macOS window tiling (Right quarters)", fn: true),
            s(ctrl, kVK_ANSI_R, "macOS window tiling (Return to previous size)", fn: true),
        ]
    }()

    /// Description of the macOS system shortcut this combination collides with,
    /// or `nil` when the combination is free.
    ///
    /// Matching is exact over ⌃⌥⇧⌘ plus the fn key; every other bit (device
    /// side bits, caps lock, numeric pad) is ignored.
    static func systemShortcutName(
        modifiers: CGEventFlags,
        keyCode: Int,
        function: Bool = false
    ) -> String? {
        let normalized = modifiers.intersection(matchedModifierMask).rawValue
        for entry in systemShortcuts
        where entry.keyCode == keyCode
            && entry.requiresFunction == function
            && entry.modifiers.intersection(matchedModifierMask).rawValue == normalized {
            return entry.name
        }
        return nil
    }

    // MARK: - Key Name Table

    private static let keyNames: [Int: String] = {
        var map: [Int: String] = [:]

        // Letters
        map[kVK_ANSI_A] = "A"; map[kVK_ANSI_B] = "B"; map[kVK_ANSI_C] = "C"
        map[kVK_ANSI_D] = "D"; map[kVK_ANSI_E] = "E"; map[kVK_ANSI_F] = "F"
        map[kVK_ANSI_G] = "G"; map[kVK_ANSI_H] = "H"; map[kVK_ANSI_I] = "I"
        map[kVK_ANSI_J] = "J"; map[kVK_ANSI_K] = "K"; map[kVK_ANSI_L] = "L"
        map[kVK_ANSI_M] = "M"; map[kVK_ANSI_N] = "N"; map[kVK_ANSI_O] = "O"
        map[kVK_ANSI_P] = "P"; map[kVK_ANSI_Q] = "Q"; map[kVK_ANSI_R] = "R"
        map[kVK_ANSI_S] = "S"; map[kVK_ANSI_T] = "T"; map[kVK_ANSI_U] = "U"
        map[kVK_ANSI_V] = "V"; map[kVK_ANSI_W] = "W"; map[kVK_ANSI_X] = "X"
        map[kVK_ANSI_Y] = "Y"; map[kVK_ANSI_Z] = "Z"

        // Numbers
        map[kVK_ANSI_0] = "0"; map[kVK_ANSI_1] = "1"; map[kVK_ANSI_2] = "2"
        map[kVK_ANSI_3] = "3"; map[kVK_ANSI_4] = "4"; map[kVK_ANSI_5] = "5"
        map[kVK_ANSI_6] = "6"; map[kVK_ANSI_7] = "7"; map[kVK_ANSI_8] = "8"
        map[kVK_ANSI_9] = "9"

        // Function keys
        map[kVK_F1] = "F1"; map[kVK_F2] = "F2"; map[kVK_F3] = "F3"
        map[kVK_F4] = "F4"; map[kVK_F5] = "F5"; map[kVK_F6] = "F6"
        map[kVK_F7] = "F7"; map[kVK_F8] = "F8"; map[kVK_F9] = "F9"
        map[kVK_F10] = "F10"; map[kVK_F11] = "F11"; map[kVK_F12] = "F12"
        map[kVK_F13] = "F13"; map[kVK_F14] = "F14"; map[kVK_F15] = "F15"
        map[kVK_F16] = "F16"; map[kVK_F17] = "F17"; map[kVK_F18] = "F18"
        map[kVK_F19] = "F19"; map[kVK_F20] = "F20"

        // Special keys
        map[kVK_Tab] = "Tab"
        map[kVK_Space] = "Space"
        map[kVK_Return] = "Return"
        map[kVK_Delete] = "Delete"
        map[kVK_ForwardDelete] = "Forward Delete"
        map[kVK_Home] = "Home"
        map[kVK_End] = "End"
        map[kVK_PageUp] = "Page Up"
        map[kVK_PageDown] = "Page Down"

        // Arrows
        map[kVK_LeftArrow] = "\u{2190}"
        map[kVK_RightArrow] = "\u{2192}"
        map[kVK_UpArrow] = "\u{2191}"
        map[kVK_DownArrow] = "\u{2193}"

        // Punctuation / symbols
        map[kVK_ANSI_Grave] = "`"
        map[kVK_ANSI_Minus] = "-"
        map[kVK_ANSI_Equal] = "="
        map[kVK_ANSI_LeftBracket] = "["
        map[kVK_ANSI_RightBracket] = "]"
        map[kVK_ANSI_Backslash] = "\\"
        map[kVK_ANSI_Semicolon] = ";"
        map[kVK_ANSI_Quote] = "'"
        map[kVK_ANSI_Comma] = ","
        map[kVK_ANSI_Period] = "."
        map[kVK_ANSI_Slash] = "/"

        return map
    }()

    /// Every key code the recorder / importer will accept as a trigger key.
    static var allowedTriggerKeyCodes: Set<Int> {
        Set(keyNames.keys).subtracting(forbiddenKeyCodes).subtracting(modifierKeyCodes)
    }
}
