import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Command Palette pane

struct CommandPalettePane: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var nav = SettingsNavigation.shared
    @ObservedObject var store: CustomCommandsStore

    @State private var editing: CustomCommand?
    @State private var isEditorPresented = false
    @State private var importMessage: String?

    private var commands: [CustomCommand] { store.commands }

    var body: some View {
        Section {
            FeatureHero(
                icon: "command",
                tint: .purple,
                title: "Command Palette",
                tagline: "One search box for everything you jump to.",
                detail: "Press \(appState.effectiveCommandPaletteShortcut.displayName) anywhere and type. Workspaces, apps, Chrome tabs and history, editor projects and HopTab actions are already there. Add your own rows below: a link, a file, a keystroke inside an app, a shell command, or text to paste.",
                steps: [
                    "Add a command and give it a short title.",
                    "Scope it to an app so it ranks first when that app is in front.",
                    "In the palette, \u{2318}N turns whatever you typed into a new command.",
                ]
            )
        }

        Section {
            if commands.isEmpty {
                VStack(spacing: HopSpacing.xs) {
                    Text("No custom commands yet")
                        .font(.hopSubheading.weight(.medium))
                    Text("Try \u{201C}Open Jira board\u{201D}, \u{201C}Split pane in Ghostty\u{201D}, or \u{201C}Paste my address\u{201D}.")
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, HopSpacing.md)
            } else {
                ForEach(grouped, id: \.key) { group in
                    if commands.count > 1 {
                        HStack(spacing: HopSpacing.xs) {
                            if let icon = group.icon {
                                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                            }
                            Text(group.title)
                                .font(.hopCaption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.top, HopSpacing.xs)
                    }
                    ForEach(group.commands) { command in
                        commandRow(command)
                    }
                }
            }
        } header: {
            HStack {
                Text("Your commands")
                Spacer()
                Button {
                    editing = nil
                    isEditorPresented = true
                } label: {
                    Label("New Command", systemImage: "plus")
                }
                .controlSize(.small)
            }
        } footer: {
            Text("Commands show in the palette with a Custom badge. Scoped commands list everywhere but rank first in their app.")
        }

        Section {
            HStack(spacing: HopSpacing.sm) {
                Button("Export\u{2026}") { exportCommands() }
                    .controlSize(.small)
                    .disabled(commands.isEmpty)
                Button("Import\u{2026}") { importCommands() }
                    .controlSize(.small)
                if let importMessage {
                    Text(importMessage)
                        .font(.hopCaption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Share")
        } footer: {
            Text("A JSON file of your commands. Importing merges by id, so re-importing a pack updates it in place.")
        }
        .sheet(isPresented: $isEditorPresented) {
            CommandEditorSheet(command: editing, draftTitle: nav.pendingCommandDraft) { result in
                if let result { store.update(result) }
                nav.pendingCommandDraft = nil
            }
            .environmentObject(appState)
        }
        .onAppear { consumeDraft() }
        .onChange(of: nav.pendingCommandDraft) { consumeDraft() }
    }

    private func consumeDraft() {
        guard nav.pendingCommandDraft != nil, !isEditorPresented else { return }
        editing = nil
        isEditorPresented = true
    }

    private struct Group {
        let key: String
        let title: String
        let icon: NSImage?
        let commands: [CustomCommand]
    }

    private var grouped: [Group] {
        var buckets: [String: [CustomCommand]] = [:]
        for command in commands { buckets[command.appBundleIdentifier ?? "", default: []].append(command) }
        return buckets.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return b.isEmpty }
            return a < b
        }.map { key in
            let first = buckets[key]!.first!
            return Group(
                key: key,
                title: key.isEmpty ? "Anywhere" : (first.appDisplayName ?? key),
                icon: key.isEmpty ? nil : first.appIcon,
                commands: buckets[key]!
            )
        }
    }

    private func commandRow(_ command: CustomCommand) -> some View {
        HStack(spacing: HopSpacing.sm + 2) {
            Image(systemName: command.action.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(command.title)
                    .lineLimit(1)
                Text("\(command.action.kindName) \u{00B7} \(command.action.summary)")
                    .font(.hopCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: HopSpacing.sm)
            Button("Edit") {
                editing = command
                isEditorPresented = true
            }
            .controlSize(.small)
            Button(role: .destructive) {
                store.remove(id: command.id)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete \(command.title)")
        }
        .padding(.vertical, 2)
    }

    private func exportCommands() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "HopTab Commands.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData().write(to: url)
            importMessage = "Exported \(commands.count)."
        } catch {
            importMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importCommands() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let count = try store.importData(try Data(contentsOf: url))
            importMessage = "Imported \(count) command\(count == 1 ? "" : "s")."
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }
}

// MARK: - Editor

private struct CommandEditorSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let original: CustomCommand?
    let onDone: (CustomCommand?) -> Void

    enum ActionKind: String, CaseIterable, Identifiable {
        case link = "Open link"
        case path = "Open file or folder"
        case shortcut = "Press shortcut in app"
        case shell = "Run shell command"
        case paste = "Paste text"
        var id: String { rawValue }
    }

    @State private var title: String
    @State private var keywords: String
    @State private var appBundleId: String
    @State private var kind: ActionKind
    @State private var link: String = ""
    @State private var path: String = ""
    @State private var shortcut: CustomShortcut?
    @State private var shell: String = ""
    @State private var paste: String = ""

    init(command: CustomCommand?, draftTitle: String?, onDone: @escaping (CustomCommand?) -> Void) {
        self.original = command
        self.onDone = onDone
        _title = State(initialValue: command?.title ?? draftTitle ?? "")
        _keywords = State(initialValue: command?.keywords ?? "")
        _appBundleId = State(initialValue: command?.appBundleIdentifier ?? "")
        switch command?.action {
        case .openURL(let s)?: _kind = State(initialValue: .link); _link = State(initialValue: s)
        case .openPath(let s)?: _kind = State(initialValue: .path); _path = State(initialValue: s)
        case .sendShortcut(let k)?: _kind = State(initialValue: .shortcut); _shortcut = State(initialValue: k)
        case .runShell(let s)?: _kind = State(initialValue: .shell); _shell = State(initialValue: s)
        case .pasteText(let s)?: _kind = State(initialValue: .paste); _paste = State(initialValue: s)
        case nil:
            let looksLikeURL = (draftTitle ?? "").contains(".") && !(draftTitle ?? "").contains(" ")
            _kind = State(initialValue: .link)
            _link = State(initialValue: looksLikeURL ? (draftTitle ?? "") : "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HopSpacing.md) {
            Text(original == nil ? "New Command" : "Edit Command")
                .font(.title3.weight(.semibold))

            Form {
                TextField("Title", text: $title, prompt: Text("What you\u{2019}ll type to find it"))
                TextField("Keywords", text: $keywords, prompt: Text("Optional, comma separated"))

                Picker("App", selection: $appBundleId) {
                    Text(kind == .shortcut ? "Choose an app\u{2026}" : "Anywhere").tag("")
                    Divider()
                    ForEach(appState.installedApps) { app in
                        Text(app.displayName).tag(app.bundleIdentifier)
                    }
                }

                Picker("Action", selection: $kind) {
                    ForEach(ActionKind.allCases) { Text($0.rawValue).tag($0) }
                }

                switch kind {
                case .link:
                    TextField("Link", text: $link, prompt: Text("https://\u{2026}"))
                case .path:
                    HStack {
                        TextField("File or folder", text: $path, prompt: Text("~/Documents/\u{2026}"))
                        Button("Choose\u{2026}") { choosePath() }
                            .controlSize(.small)
                    }
                case .shortcut:
                    LabeledContent("Shortcut") {
                        ShortcutRecorderView(shortcut: $shortcut, mode: .exactModifiers)
                    }
                case .shell:
                    TextField("Command", text: $shell, prompt: Text("open -a Finder ~/Downloads"))
                        .font(.body.monospaced())
                case .paste:
                    TextEditor(text: $paste)
                        .font(.body)
                        .frame(minHeight: 70, maxHeight: 140)
                        .overlay(RoundedRectangle(cornerRadius: HopRadius.control).stroke(Color.secondary.opacity(0.3)))
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Text(hint)
                .font(.hopCaption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel") { onDone(nil); dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(original == nil ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValid)
            }
        }
        .padding(HopSpacing.lg)
        .frame(width: 520)
        .onAppear { appState.ensureInstalledAppsLoaded() }
    }

    private var hint: String {
        switch kind {
        case .link: return appBundleId.isEmpty ? "Opens with your default browser or app for that link." : "Opens the link with the chosen app."
        case .path: return appBundleId.isEmpty ? "Opens with the default app for that file." : "Opens the file with the chosen app."
        case .shortcut: return "HopTab brings the app to the front, then presses the keys. Works for any shortcut the app accepts from the keyboard."
        case .shell: return "Runs in a login shell in the background. Output is discarded. Only commands you type here are ever run."
        case .paste: return "Copies the text and presses \u{2318}V in the chosen app, or in whatever app was in front."
        }
    }

    private var isValid: Bool {
        guard !title.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        switch kind {
        case .link: return !link.trimmingCharacters(in: .whitespaces).isEmpty
        case .path: return !path.trimmingCharacters(in: .whitespaces).isEmpty
        case .shortcut: return shortcut != nil && !appBundleId.isEmpty
        case .shell: return !shell.trimmingCharacters(in: .whitespaces).isEmpty
        case .paste: return !paste.isEmpty
        }
    }

    private func save() {
        let action: CustomCommand.Action
        switch kind {
        case .link: action = .openURL(link.trimmingCharacters(in: .whitespaces))
        case .path: action = .openPath(path.trimmingCharacters(in: .whitespaces))
        case .shortcut: action = .sendShortcut(shortcut!)
        case .shell: action = .runShell(shell)
        case .paste: action = .pasteText(paste)
        }
        let command = CustomCommand(
            id: original?.id ?? UUID(),
            title: title.trimmingCharacters(in: .whitespaces),
            keywords: keywords,
            appBundleIdentifier: appBundleId.isEmpty ? nil : appBundleId,
            action: action
        )
        onDone(command)
        dismiss()
    }

    private func choosePath() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        path = (url.path as NSString).abbreviatingWithTildeInPath
    }
}
