import SwiftUI

@main
struct HopTabApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(delegate.appState)
        } label: {
            MenuBarLabel(appState: delegate.appState)
        }
    }
}

/// Plain icon normally; "<meeting> in 4m" countdown when one is imminent.
private struct MenuBarLabel: View {
    @ObservedObject var appState: AppState

    var body: some View {
        if let hud = appState.meetingHUD {
            HStack(spacing: 4) {
                Image(systemName: "video.fill")
                Text(hud)
            }
        } else {
            Image(systemName: "arrow.2.squarepath")
        }
    }
}
