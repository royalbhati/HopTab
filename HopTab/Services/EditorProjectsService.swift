import AppKit
import Foundation
import SQLite3

/// Recent projects from VS Code-family editors (VSCodium, VS Code, Insiders,
/// Cursor) for the ⌥K palette.
///
/// Two sources, merged: the editor's `history.recentlyOpenedPathsList` in
/// its global state database (ordered, when present) and the per-workspace
/// storage folders, whose modification time says when the project was last
/// open (VSCodium builds no longer write the list). Safe off-main. Never
/// launches an editor; opening is `NSWorkspace`'s job.
enum EditorProjectsService {
    struct Editor: Hashable {
        let name: String
        let bundleIdentifier: String
        /// Folder name under ~/Library/Application Support.
        let supportDirectory: String
    }

    static let editors: [Editor] = [
        Editor(name: "VSCodium", bundleIdentifier: "com.vscodium", supportDirectory: "VSCodium"),
        Editor(name: "Visual Studio Code", bundleIdentifier: "com.microsoft.VSCode", supportDirectory: "Code"),
        Editor(name: "VS Code Insiders", bundleIdentifier: "com.microsoft.VSCodeInsiders", supportDirectory: "Code - Insiders"),
        Editor(name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92", supportDirectory: "Cursor"),
    ]

    /// Bundle identifiers of every editor this service knows about.
    static var bundleIdentifiers: Set<String> { Set(editors.map(\.bundleIdentifier)) }

    static func installedEditors() -> [Editor] {
        editors.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleIdentifier) != nil }
    }

    struct Project: Equatable {
        let name: String
        let url: URL
        let editor: Editor
        /// Seconds since 1970 the project was last open, 0 when unknown.
        let lastOpened: TimeInterval
        var isWorkspaceFile: Bool { url.pathExtension == "code-workspace" }
    }

    /// Recent projects for one editor, most recent first, deduplicated by path.
    static func recentProjects(for editor: Editor, limit: Int = 60) -> [Project] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/\(editor.supportDirectory)/User", isDirectory: true)
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }

        var byPath: [String: Project] = [:]
        var order: [String] = []

        // 1. Workspace storage: one folder per project, mtime = last open.
        let storage = base.appendingPathComponent("workspaceStorage", isDirectory: true)
        if let dirs = try? FileManager.default.contentsOfDirectory(
            at: storage, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) {
            for dir in dirs {
                let meta = dir.appendingPathComponent("workspace.json")
                guard let data = try? Data(contentsOf: meta),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }
                let uriString = (json["folder"] as? String)
                    ?? ((json["workspace"] as? String))
                    ?? ((json["configuration"] as? [String: Any])?["external"] as? String)
                guard let uriString, let url = URL(string: uriString), url.isFileURL else { continue }
                let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                let project = Project(name: displayName(for: url), url: url, editor: editor, lastOpened: mtime)
                if let existing = byPath[url.path], existing.lastOpened >= mtime { continue }
                if byPath[url.path] == nil { order.append(url.path) }
                byPath[url.path] = project
            }
        }

        // 2. The editor's own recent list, when it keeps one. Entries are
        //    ordered newest first; give them a synthetic recency above
        //    anything the folder scan found so the editor's order wins.
        let listed = recentlyOpenedList(in: base.appendingPathComponent("globalStorage/state.vscdb"))
        if !listed.isEmpty {
            let top = (byPath.values.map(\.lastOpened).max() ?? Date().timeIntervalSince1970) + 1
            for (i, url) in listed.enumerated() {
                let recency = top + Double(listed.count - i)
                let project = Project(name: displayName(for: url), url: url, editor: editor, lastOpened: recency)
                if byPath[url.path] == nil { order.append(url.path) }
                byPath[url.path] = project
            }
        }

        return order
            .compactMap { byPath[$0] }
            .filter { FileManager.default.fileExists(atPath: $0.url.path) }
            .sorted { $0.lastOpened > $1.lastOpened }
            .prefix(limit)
            .map { $0 }
    }

    /// Open a project in its editor.
    static func open(_ project: Project) {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: project.editor.bundleIdentifier) else {
            NSWorkspace.shared.open(project.url)
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([project.url], withApplicationAt: app, configuration: config)
    }

    // MARK: - Helpers

    private static func displayName(for url: URL) -> String {
        var name = url.lastPathComponent
        if url.pathExtension == "code-workspace" { name = url.deletingPathExtension().lastPathComponent }
        return name.isEmpty ? url.path : name
    }

    /// `history.recentlyOpenedPathsList` → folder / workspace URLs, in order.
    /// The database is copied first; the editor keeps it open.
    private static func recentlyOpenedList(in source: URL) -> [URL] {
        guard FileManager.default.fileExists(atPath: source.path) else { return [] }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("hoptab-editor-state-\(UUID().uuidString).db")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard (try? FileManager.default.copyItem(at: source, to: temp)) != nil else { return [] }

        var db: OpaquePointer?
        guard sqlite3_open_v2(temp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = 'history.recentlyOpenedPathsList'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return [] }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0) else { return [] }
        let json = String(cString: text)
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = root["entries"] as? [[String: Any]]
        else { return [] }

        return entries.compactMap { entry in
            let uri = (entry["folderUri"] as? String)
                ?? ((entry["workspace"] as? [String: Any])?["configPath"] as? String)
            guard let uri, let url = URL(string: uri), url.isFileURL else { return nil }
            return url
        }
    }
}
