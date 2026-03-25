import Carbon.HIToolbox
import CoreGraphics
import Foundation

struct SnapShortcutConfig: Codable {
    var bindings: [SnapDirection: CustomShortcut]

    /// Rectangle-compatible defaults.
    static let defaults: SnapShortcutConfig = {
        let ctrlOpt = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
        let ctrlOptCmd = ctrlOpt | CGEventFlags.maskCommand.rawValue

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
            // Monitor movement
            .nextMonitor:     shortcut(ctrlOptCmd, kVK_RightArrow),
            .previousMonitor: shortcut(ctrlOptCmd, kVK_LeftArrow),
            // Undo
            .undo:           shortcut(ctrlOpt, kVK_ANSI_Z),
            // Universal cycle
            .cycleNext:      shortcut(ctrlOpt, kVK_ANSI_Period),
            .cyclePrevious:  shortcut(ctrlOpt, kVK_ANSI_Comma),
        ])
    }()

    // MARK: - Persistence

    private static let storageKey = "snapShortcuts"

    static var current: SnapShortcutConfig {
        get {
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
