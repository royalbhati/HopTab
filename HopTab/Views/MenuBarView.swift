import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var updateService = UpdateService.shared

    var body: some View {
        VStack(spacing: 0) {
            // Update available banner
            if let update = updateService.availableUpdate {
                Button {
                    updateService.downloadUpdate(update)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.white)
                        Text("Update v\(update.version) available")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                        Spacer()
                        Text("Download")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

                Divider()
            }

            // Accessibility permission banner
            if !appState.permissions.isTrusted {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .foregroundStyle(.white)
                        Text("HopTab needs Accessibility permission to work")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                    }

                    Button {
                        appState.permissions.requestAccessibility()
                    } label: {
                        Text("Grant Accessibility Access")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Color.white.opacity(0.15))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.orange)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 4)
                .padding(.vertical, 2)

                Divider()
            }

            // Hotkey hint
            HStack(spacing: 6) {
                Image(systemName: "keyboard")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(appState.appShortcutSelection.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if appState.hotkeyStatus == .running {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                } else if appState.hotkeyStatus == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
            }
            .padding(.horizontal, 4)

            Divider()

            // Profile switcher
            if appState.store.profiles.count > 1 {
                Menu {
                    ForEach(appState.store.profiles) { profile in
                        Button {
                            appState.activateProfile(id: profile.id)
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

                // Layout action
                if let profile = appState.store.activeProfile,
                   let binding = profile.layoutBinding,
                   !binding.zoneAssignments.isEmpty {
                    Button {
                        appState.applyLayoutForActiveProfile()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "rectangle.3.group")
                            Text("Apply Layout")
                        }
                    }
                }

                // Session actions for active profile
                if let profileId = appState.store.activeProfileId {
                    if appState.canRestoreSession(profileId: profileId) {
                        Button {
                            appState.restoreSession(profileId: profileId)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.counterclockwise")
                                Text("Restore Session")
                            }
                        }
                    }

                    if SessionSnapshotService.hasRunningApps(appState.store.activeProfile!) {
                        Button {
                            appState.saveAndCloseSession(profileId: profileId)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "tray.and.arrow.down")
                                Text("Save & Close Session")
                            }
                        }
                    }

                    Divider()
                }
            } else {
                // Empty state — check if there's a saved session to restore
                if let profileId = appState.store.activeProfileId,
                   appState.canRestoreSession(profileId: profileId) {
                    Button {
                        appState.restoreSession(profileId: profileId)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.counterclockwise")
                            Text("Restore Session")
                        }
                    }

                    Divider()
                } else {
                    VStack(spacing: 6) {
                        Text("No apps pinned")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text("Open Settings to pin your first app")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 8)

                    Divider()
                }
            }

            Button("Settings...") {
                NSApp.sendAction(#selector(AppDelegate.openSettings(_:)), to: nil, from: nil)
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
