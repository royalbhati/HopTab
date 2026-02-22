import Carbon.HIToolbox
import CoreGraphics

enum KeyCodeMapping {
    // MARK: - Key Code to Display Name

    static func displayName(for keyCode: Int) -> String? {
        return keyNames[keyCode]
    }

    // MARK: - Modifier Display Names

    static func modifierDisplayNames(for flags: CGEventFlags) -> [String] {
        var names: [String] = []
        if flags.contains(.maskControl)   { names.append("\u{2303}Control") }
        if flags.contains(.maskAlternate) { names.append("\u{2325}Option") }
        if flags.contains(.maskShift)     { names.append("\u{21E7}Shift") }
        if flags.contains(.maskCommand)   { names.append("\u{2318}Command") }
        return names
    }

    static func modifierSymbols(for flags: CGEventFlags) -> String {
        var s = ""
        if flags.contains(.maskControl)   { s += "\u{2303}" }
        if flags.contains(.maskAlternate) { s += "\u{2325}" }
        if flags.contains(.maskShift)     { s += "\u{21E7}" }
        if flags.contains(.maskCommand)   { s += "\u{2318}" }
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
}
