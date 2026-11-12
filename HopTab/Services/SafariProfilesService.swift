import AppKit
import ApplicationServices

/// Safari profiles for workspaces and the command palette.
///
/// Safari has no profile API: nothing in its scripting dictionary, no
/// command-line flag, nothing readable on disk that names them. What it
/// does have, once profiles are set up, is a "New <Profile> Window" item
/// per profile in the File menu and a profile button on every window's
/// toolbar. This service reads both through Accessibility, which HopTab
/// already holds for window switching.
///
/// Profile names are cached in UserDefaults so the workspace picker can
/// offer them while Safari is not running. Nothing here launches Safari
/// except `switchToProfile`, which needs it open to show a window.
enum SafariProfilesService {
    static let bundleIdentifier = "com.apple.Safari"
    private static let cacheKey = "safariProfileNamesCache"
    private static let axQueue = DispatchQueue(label: "com.hoptab.SafariProfiles.ax", qos: .userInitiated)

    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }

    static var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
    }

    static var icon: NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return nil }
        return InstalledAppsService.icon(forPath: url.path)
    }

    /// Profile names last seen in Safari's File menu.
    static var cachedProfileNames: [String] {
        UserDefaults.standard.stringArray(forKey: cacheKey) ?? []
    }

    // MARK: - Discovery

    /// Profile names from Safari's File menu, or the cached list when
    /// Safari is not running. Safe off the main thread.
    @discardableResult
    static func profileNames() -> [String] {
        guard let app = runningApp else { return cachedProfileNames }
        let names = newWindowMenuItems(pid: app.processIdentifier).map(\.name)
        // An empty result while Safari is running is the truth: the user has
        // no profiles (or just removed them).
        UserDefaults.standard.set(names, forKey: cacheKey)
        return names
    }

    /// Bring the profile's window to the front; open one if Safari has none
    /// for it. Launches Safari when it is not running.
    static func switchToProfile(name: String) {
        guard let app = runningApp else {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config) { app, _ in
                guard app != nil else { return }
                // Safari restores its windows first; give the menu a moment.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    switchToProfile(name: name)
                }
            }
            return
        }
        let pid = app.processIdentifier
        axQueue.async {
            if let window = windows(pid: pid).first(where: { windowProfileName($0, candidates: [name]) == name }) {
                DispatchQueue.main.async { app.activate(options: .activateIgnoringOtherApps) }
                // Activation raises Safari's current key window; let that
                // settle, then put the profile's window on top of it.
                axQueue.asyncAfter(deadline: .now() + 0.25) {
                    var minimized: CFTypeRef?
                    if AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                       minimized as? Bool == true {
                        AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFBoolean)
                    }
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                }
                return
            }
            guard let item = newWindowMenuItems(pid: pid).first(where: { $0.name == name }) else { return }
            DispatchQueue.main.async { app.activate(options: .activateIgnoringOtherApps) }
            AXUIElementPerformAction(item.element, kAXPressAction as CFString)
        }
    }

    // MARK: - Accessibility

    private struct NewWindowItem {
        let name: String
        let element: AXUIElement
    }

    /// "New <Profile> Window" items of the File menu. "New Window" and
    /// "New Private Window" are not profiles and are skipped.
    private static func newWindowMenuItems(pid: pid_t) -> [NewWindowItem] {
        let appElement = AXUIElementCreateApplication(pid)
        guard let menuBar: AXUIElement = child(appElement, kAXMenuBarAttribute),
              let fileItem = children(menuBar).first(where: { title($0) == "File" }),
              let fileMenu = children(fileItem).first
        else { return [] }

        var out: [NewWindowItem] = []
        for item in children(fileMenu) {
            guard let t = title(item), t.hasPrefix("New "), t.hasSuffix(" Window") else { continue }
            if t == "New Window" || t == "New Private Window" { continue }
            let name = String(t.dropFirst("New ".count).dropLast(" Window".count))
            guard !name.isEmpty, name != "Private" else { continue }
            out.append(NewWindowItem(name: name, element: item))
        }
        return out
    }

    private static func windows(pid: pid_t) -> [AXUIElement] {
        let appElement = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &ref) == .success,
              let list = ref as? [AXUIElement] else { return [] }
        return list
    }

    /// The profile a window belongs to, found through the profile button on
    /// its toolbar whose title or description is one of `candidates`.
    static func windowProfileName(_ window: AXUIElement, candidates: [String]) -> String? {
        guard !candidates.isEmpty else { return nil }
        let set = Set(candidates)
        var toolbar: AXUIElement? = child(window, "AXToolbar")
        if toolbar == nil {
            toolbar = children(window).first(where: { role($0) == (kAXToolbarRole as String) })
        }
        guard let toolbar else { return nil }
        return search(toolbar, depth: 0) { element in
            for attr in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                if let s = string(element, attr as String), set.contains(s) { return s }
            }
            return nil
        }
    }

    private static func search(_ element: AXUIElement, depth: Int, _ probe: (AXUIElement) -> String?) -> String? {
        if let hit = probe(element) { return hit }
        guard depth < 4 else { return nil }
        for c in children(element) {
            if let hit = search(c, depth: depth + 1, probe) { return hit }
        }
        return nil
    }

    private static func child(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success, let ref else { return nil }
        return (ref as! AXUIElement)
    }

    private static func children(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let list = ref as? [AXUIElement] else { return [] }
        return list
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func title(_ element: AXUIElement) -> String? { string(element, kAXTitleAttribute as String) }
    private static func role(_ element: AXUIElement) -> String? { string(element, kAXRoleAttribute as String) }
}
