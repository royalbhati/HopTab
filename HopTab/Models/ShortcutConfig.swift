import Carbon.HIToolbox
import CoreGraphics

enum ShortcutPreset: String, Codable, CaseIterable, Identifiable {
    case optionTab
    case controlTab
    case optionBacktick

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .optionTab: return "\u{2325} Option + Tab"
        case .controlTab: return "\u{2303} Control + Tab"
        case .optionBacktick: return "\u{2325} Option + `"
        }
    }

    var modifierFlag: CGEventFlags {
        switch self {
        case .optionTab, .optionBacktick: return .maskAlternate
        case .controlTab: return .maskControl
        }
    }

    var keyCode: Int64 {
        switch self {
        case .optionTab, .controlTab: return Int64(kVK_Tab)
        case .optionBacktick: return Int64(kVK_ANSI_Grave)
        }
    }

    var keyName: String {
        switch self {
        case .optionTab, .controlTab: return "Tab"
        case .optionBacktick: return "`"
        }
    }

    var modifierName: String {
        switch self {
        case .optionTab, .optionBacktick: return "Option"
        case .controlTab: return "Control"
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
