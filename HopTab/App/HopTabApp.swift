import SwiftUI

@main
struct HopTabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("HopTab", systemImage: "arrow.2.squarepath") {
            MenuBarView()
                .environmentObject(delegate.appState)
        }

        Settings {
            SettingsView()
                .environmentObject(delegate.appState)
        }
    }
}
