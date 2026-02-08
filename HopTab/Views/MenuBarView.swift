import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Profile switcher
            if appState.store.profiles.count > 1 {
                Menu {
                    ForEach(appState.store.profiles) { profile in
                        Button {
                            appState.store.setActiveProfile(id: profile.id)
                        } label: {
                            HStack {
                                Text(profile.name)
                                if profile.id == appState.store.activeProfileId {
                                    Text("(\(profile.pinnedApps.count))")
                                }
                            }
                        }
                        .disabled(profile.id == appState.store.activeProfileId)
                    }
                } label: {
                    HStack {
                        Image(systemName: "person.2.fill")
                            .font(.system(size: 10))
                        Text(appState.store.activeProfile?.name ?? "Default")
                            .fontWeight(.medium)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider()
            }

            // Pinned apps in active profile
            if !appState.store.apps.isEmpty {
                ForEach(appState.store.apps) { app in
                    Button {
                        AppSwitcherService.activate(app)
                    } label: {
                        HStack {
                            Image(nsImage: app.icon)
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(app.displayName)
                            Spacer()
                            Circle()
                                .fill(app.isRunning ? Color.green : Color.gray.opacity(0.3))
                                .frame(width: 6, height: 6)
                        }
                    }
                }

                Divider()
            }

            SettingsLink {
                Text("Settings...")
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit HopTab") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
