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


struct CustomShortcut: Codable, Equatable {
    let modifierFlagsRawValue: UInt64
    let keyCode: Int64

    var modifierFlags: CGEventFlags {
        CGEventFlags(rawValue: modifierFlagsRawValue)
    }

    var keyName: String {
        KeyCodeMapping.displayName(for: Int(keyCode)) ?? "Key \(keyCode)"
    }

    var modifierName: String {
        let names = KeyCodeMapping.modifierDisplayNames(for: modifierFlags)
        return names.isEmpty ? "" : names.joined(separator: " + ")
    }

    var displayName: String {
        let mods = KeyCodeMapping.modifierSymbols(for: modifierFlags)
        return "\(mods)\(keyName)"
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
